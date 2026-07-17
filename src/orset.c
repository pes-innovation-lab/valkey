/*
 * Copyright (c) Valkey Contributors
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "orset.h"
#include "endianconv.h"
#include "hashtable.h"
#include "zmalloc.h"
#include <string.h>

/*======================= Command Handler Structs =========================== */

typedef struct orsetParsedMeta {
    int is_sadd;
    int ntags;
    orsetTag *tags;
} orsetParsedMeta;

typedef struct orsetCommandHandler {
    multimasterCommandHandler handler;
    orsetParsedMeta parsed;
} orsetCommandHandler;

/*==================== HashtableType Implementations ======================== */

const void *orsetGetKey(const void *entry) {
    return ((orset *)entry)->comp_key;
}

void orsetDestructor(void *entry) {
    orsetFree((orset *)entry);
}

hashtableType orsetHashtableType = {
    .entryGetKey = orsetGetKey,
    .hashFunction = dictSdsHash,
    .keyCompare = dictSdsKeyCompare,
    .entryDestructor = orsetDestructor,
};

const void *orsetEntryGetKey(const void *entry) {
    return ((orsetEntry *)entry)->member;
}

void orsetEntryDestructor(void *entry) {
    if (!entry) return;
    orsetEntry *e = entry;
    sdsfree(e->member);
    hashtableRelease(e->tagset);
    zfree(e);
}

hashtableType orsetEntryHashtableType = {
    .entryGetKey = orsetEntryGetKey,
    .hashFunction = dictSdsHash,
    .keyCompare = dictSdsKeyCompare,
    .entryDestructor = orsetEntryDestructor,
};

uint64_t orsetTagHash(const void *key) {
    const orsetTag *tag = key;
    uint64_t hash = hashtableGenHashFunction(tag->node_id, CONFIG_RUN_ID_SIZE);
    hash ^= tag->ts.wall_time * 0x9e3779b97f4a7c15ULL;
    hash ^= tag->ts.logical * 0x6c62272e07bb0142ULL;
    return hash;
}

int orsetTagKeyCompare(const void *k1, const void *k2) {
    const orsetTag *a = k1, *b = k2;
    return (memcmp(a->node_id, b->node_id, CONFIG_RUN_ID_SIZE) == 0) &&
           (hlcCompare(&a->ts, &b->ts) == 0);
}

void orsetTagDestructor(void *entry) {
    zfree(entry);
}

hashtableType orsetTagHashtableType = {
    .hashFunction = orsetTagHash,
    .keyCompare = orsetTagKeyCompare,
    .entryDestructor = orsetTagDestructor,
};

/*============================ Helper Functions ==============================*/

sds orsetComposeKey(int dbid, sds keyname) {
    uint64_t dbid_be = htonu64((uint64_t)(uint32_t)dbid);
    sds key = sdsnewlen(&dbid_be, sizeof(dbid_be));
    key = sdscatlen(key, keyname, sdslen(keyname));
    return key;
}

orset *orsetGetOrCreate(int dbid, sds keyname) {
    orset *os = orsetLookup(dbid, keyname);
    if (os == NULL) {
        sds comp = orsetComposeKey(dbid, keyname);
        os = orsetCreate(comp);
        hashtableAdd(server.orsets, os);
    }
    return os;
}

orsetEntry *orsetGetOrCreateEntry(orset *os, sds member) {
    void *existing = NULL;
    if (hashtableFind(os->entries, member, &existing))
        return existing;
    orsetEntry *e = zcalloc(sizeof(orsetEntry));
    e->member = sdsdup(member);
    e->tagset = hashtableCreate(&orsetTagHashtableType);
    hashtableAdd(os->entries, e);
    return e;
}

/*========================== OR-Set Functions ================================*/

orset *orsetCreate(sds comp_key) {
    orset *os = zcalloc(sizeof(orset));
    os->comp_key = comp_key;
    os->entries = hashtableCreate(&orsetEntryHashtableType);
    return os;
}

void orsetFree(orset *os) {
    if (!os) return;
    hashtableRelease(os->entries);
    sdsfree(os->comp_key);
    zfree(os);
}

orset *orsetLookup(int dbid, sds keyname) {
    sds comp = orsetComposeKey(dbid, keyname);
    void *existing = NULL;
    if (hashtableFind(server.orsets, comp, &existing)) {
        sdsfree(comp);
        return (orset *)existing;
    }
    sdsfree(comp);
    return NULL;
}

/* Add member locally. Returns the tag created for this addition. */
orsetTag *orsetAddMember(int dbid, sds key, sds member) {
    orset *os = orsetGetOrCreate(dbid, key);
    orsetEntry *ent = orsetGetOrCreateEntry(os, member);

    orsetTag *tag = zcalloc(sizeof(orsetTag));
    memcpy(tag->node_id, server.runid, CONFIG_RUN_ID_SIZE);
    tag->ts = server.hlc_clock;
    hashtableAdd(ent->tagset, tag);
    return tag;
}

/* Collect tags locally for deletion propagation. Returns the number of
 * tags collected and sets *tags_out to an array of orsetTag pointers. */
int orsetCollectTagsForMember(int dbid, sds key, sds member, orsetTag ***tags_out) {
    *tags_out = NULL;
    orset *os = orsetLookup(dbid, key);
    if (!os) return 0;

    void *existing = NULL;
    if (!hashtableFind(os->entries, member, &existing)) return 0;
    orsetEntry *ent = existing;

    int n = (int)hashtableSize(ent->tagset);
    if (n == 0) return 0;

    orsetTag **arr = zcalloc(sizeof(orsetTag *) * n);
    int i = 0;
    hashtableIterator it;
    hashtableInitIterator(&it, ent->tagset, 0);
    void *tag_ptr;
    while (hashtableNext(&it, &tag_ptr)) arr[i++] = tag_ptr;
    hashtableCleanupIterator(&it);

    *tags_out = arr;
    return i;
}

void orsetDelete(int dbid, sds key) {
    sds comp = orsetComposeKey(dbid, key);
    hashtableDelete(server.orsets, comp);
    sdsfree(comp);
}

/* Apply replica additions to an orset */
void orsetApplySadd(int dbid, sds key, sds member, const orsetTag *tag) {
    orset *os = orsetGetOrCreate(dbid, key);
    orsetEntry *ent = orsetGetOrCreateEntry(os, member);

    orsetTag *owned = zmalloc(sizeof(orsetTag));
    *owned = *tag;
    hashtableAdd(ent->tagset, owned);
}

/* Apply replica deletions to orset metadata */
void orsetApplySrem(int dbid, sds key, sds member, orsetTag **tags, int ntags) {
    orset *os = orsetLookup(dbid, key);
    if (!os) return;

    void *existing = NULL;
    if (!hashtableFind(os->entries, member, &existing)) return;
    orsetEntry *ent = existing;

    for (int i = 0; i < ntags; i++)
        hashtableDelete(ent->tagset, tags[i]);

    if (hashtableSize(ent->tagset) == 0) {
        hashtableDelete(os->entries, member);
        if (hashtableSize(os->entries) == 0) {
            sds comp = orsetComposeKey(dbid, key);
            hashtableDelete(server.orsets, comp);
            sdsfree(comp);
        }
    }
}

/*========================== Command Handler Functions =======================*/

/* Parse OR-Set metadata from a raw command string. The expected format is:
 * <cmd>,<node_id>:<wall_time>:<logical>[,<node_id>:<wall_time>:<logical>...] */
int orsetMetadataParse(multimasterCommandHandler *self, sds raw) {
    orsetCommandHandler *osh = (orsetCommandHandler *)self;

    /* Reset previous parsing state */
    if (osh->parsed.tags) {
        zfree(osh->parsed.tags);
        osh->parsed.tags = NULL;
    }

    osh->parsed.ntags = 0;
    osh->parsed.is_sadd = (strncmp(raw, "sadd", 4) == 0);

    char *body = strchr(raw, ',');
    if (!body) return C_OK; /* No tags */
    body++;                 /* Skip comma */

    int count = 1;
    for (char *p = body; *p; p++)
        if (*p == ',') count++;

    osh->parsed.tags = zmalloc(sizeof(orsetTag) * count);
    int filled = 0;
    char *tok = body;
    while (tok && *tok) {
        char *comma = strchr(tok, ',');
        if (comma) *comma = '\0';

        if ((int)strlen(tok) > CONFIG_RUN_ID_SIZE + 1) {
            char *rest = tok + CONFIG_RUN_ID_SIZE + 1;
            unsigned long long wall = 0, logical = 0;
            if (sscanf(rest, "%llu:%llu", &wall, &logical) == 2) {
                memcpy(osh->parsed.tags[filled].node_id, tok, CONFIG_RUN_ID_SIZE);
                osh->parsed.tags[filled].node_id[CONFIG_RUN_ID_SIZE] = '\0';
                osh->parsed.tags[filled].ts.wall_time = wall;
                osh->parsed.tags[filled].ts.logical = logical;
                filled++;
            }
        }

        if (comma) *comma = ',';
        tok = comma ? comma + 1 : NULL;
    }
    osh->parsed.ntags = filled;
    return C_OK;
}

robj *orsetSaddSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    UNUSED(self);
    UNUSED(cmd);
    if (argc < 3) return createStringObject("none", 4);

    sds key = objectGetVal(argv[1]);
    serverDb *db = server.executing_client ? server.executing_client->db : server.db[0];
    orset *os = orsetLookup(db->id, key);
    if (!os) return createStringObject("none", 4);

    sds buf = sdsnew("sadd");
    for (int j = 2; j < argc; j++) {
        sds member = objectGetVal(argv[j]);
        void *ent_ptr = NULL;
        if (!hashtableFind(os->entries, member, &ent_ptr)) continue;
        orsetEntry *ent = ent_ptr;

        /* Find the tag with the highest HLC (the one we just created in resolve) */
        orsetTag *latest = NULL;
        hashtableIterator it;
        hashtableInitIterator(&it, ent->tagset, 0);
        void *tp;
        while (hashtableNext(&it, &tp)) {
            orsetTag *t = tp;
            if (!latest || hlcCompare(&t->ts, &latest->ts) > 0) latest = t;
        }
        hashtableCleanupIterator(&it);

        if (latest) {
            buf = sdscatfmt(buf, ",%s:%U:%U",
                            latest->node_id,
                            (unsigned long long)latest->ts.wall_time,
                            (unsigned long long)latest->ts.logical);
        }
    }
    robj *meta = createStringObject(buf, sdslen(buf));
    sdsfree(buf);
    return meta;
}

robj *orsetSremSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    UNUSED(self);
    UNUSED(cmd);
    UNUSED(argv);
    UNUSED(argc);
    if (server.orset_deleted_tags) {
        robj *meta = createStringObject(server.orset_deleted_tags, sdslen(server.orset_deleted_tags));
        sdsfree(server.orset_deleted_tags);
        server.orset_deleted_tags = NULL;
        return meta;
    }
    return createStringObject("none", 4);
}

void orsetResolve(multimasterCommandHandler *self, client *c) {
    orsetCommandHandler *osh = (orsetCommandHandler *)self;
    sds key = objectGetVal(c->argv[1]);

    if (!c->flag.fake) {
        /* LOCAL CLIENT WRITE (SADD/SREM)
         * 1. Update the OR-Set metadata. */
        if (osh->handler.serialize == orsetSaddSerialize) {
            /* SADD local: Add a new HLC tag for each member */
            for (int j = 2; j < c->argc; j++) {
                sds member = objectGetVal(c->argv[j]);
                orsetAddMember(c->db->id, key, member);
            }
        } else {
            /* SREM local: Stash current tags for serialization, then remove from OR-Set */
            if (server.orset_deleted_tags) sdsfree(server.orset_deleted_tags);
            server.orset_deleted_tags = sdsnew("srem");

            for (int j = 2; j < c->argc; j++) {
                sds member = objectGetVal(c->argv[j]);
                orsetTag **tags = NULL;
                int ntags = orsetCollectTagsForMember(c->db->id, key, member, &tags);
                for (int k = 0; k < ntags; k++) {
                    server.orset_deleted_tags = sdscatfmt(
                        server.orset_deleted_tags, ",%s:%U:%U",
                        tags[k]->node_id,
                        (unsigned long long)tags[k]->ts.wall_time,
                        (unsigned long long)tags[k]->ts.logical);
                }
                if (ntags > 0) {
                    orsetApplySrem(c->db->id, key, member, tags, ntags);
                }
                if (tags) zfree(tags);
            }
        }

        /* 2. Execute standard database command logic (mutates Set, handles AOF, replies, dirty++) */
        call(c, CMD_CALL_FULL);
        return;
    }

    /* REPLICATED WRITE (SADD/SREM Replay)
     * 1. Save original client parameters. */
    robj **orig_argv = c->argv;
    int orig_argc = c->argc;
    struct serverCommand *orig_cmd = c->cmd;
    struct serverCommand *orig_lastcmd = c->lastcmd;
    struct serverCommand *orig_realcmd = c->realcmd;

    /* 2. Process each member in the payload. */
    for (int j = 2; j < orig_argc; j++) {
        sds member = objectGetVal(orig_argv[j]);
        int is_sadd = osh->parsed.is_sadd;

        if (is_sadd) {
            if ((j - 2) < osh->parsed.ntags) {
                orsetApplySadd(c->db->id, key, member, &osh->parsed.tags[j - 2]);
            }
        } else {
            /* Build a temporary array of pointers to the parsed tags */
            orsetTag **temp_tags = zmalloc(sizeof(orsetTag *) * osh->parsed.ntags);
            for (int k = 0; k < osh->parsed.ntags; k++) {
                temp_tags[k] = &osh->parsed.tags[k];
            }
            orsetApplySrem(c->db->id, key, member, temp_tags, osh->parsed.ntags);
            zfree(temp_tags);
        }

        /* 3. Determine if the element state in the database needs to change. */
        robj *setobj = lookupKeyWrite(c->db, orig_argv[1]);
        int member_exists = setobj && setTypeIsMember(setobj, member);

        orset *os = orsetLookup(c->db->id, key);
        void *ent_ptr = NULL;
        int should_exist = os && hashtableFind(os->entries, member, &ent_ptr);

        int execute_mutation = 0;
        char *mutate_cmd = NULL;

        if (should_exist && !member_exists) {
            execute_mutation = 1;
            mutate_cmd = "SADD";
        } else if (!should_exist && member_exists) {
            execute_mutation = 1;
            mutate_cmd = "SREM";
        }

        /* 4. Trigger specific mutation on the database if necessary. */
        if (execute_mutation) {
            robj *temp_argv[3];
            temp_argv[0] = createStringObject(mutate_cmd, 4);
            temp_argv[1] = orig_argv[1];
            temp_argv[2] = orig_argv[j];
            incrRefCount(temp_argv[0]);
            incrRefCount(temp_argv[1]);
            incrRefCount(temp_argv[2]);

            c->argv = temp_argv;
            c->argc = 3;
            c->cmd = lookupCommand(c->argv, 3);
            c->lastcmd = c->cmd;
            c->realcmd = c->cmd;

            call(c, CMD_CALL_PROPAGATE_AOF);

            decrRefCount(temp_argv[0]);
            decrRefCount(temp_argv[1]);
            decrRefCount(temp_argv[2]);
        }
    }

    /* 5. Restore original client context. */
    c->argv = orig_argv;
    c->argc = orig_argc;
    c->cmd = orig_cmd;
    c->lastcmd = orig_lastcmd;
    c->realcmd = orig_realcmd;

    /* 6. Free parsed metadata tags. */
    if (osh->parsed.tags) {
        zfree(osh->parsed.tags);
        osh->parsed.tags = NULL;
    }
    osh->parsed.ntags = 0;
}

/*========================== Command Handler Registration ====================*/

orsetCommandHandler saddOrsetHandler = {
    .handler = {
        .parse = orsetMetadataParse,
        .serialize = orsetSaddSerialize,
        .resolve = orsetResolve},
    .parsed = {0, 0, NULL}};

orsetCommandHandler sremOrsetHandler = {
    .handler = {
        .parse = orsetMetadataParse,
        .serialize = orsetSremSerialize,
        .resolve = orsetResolve},
    .parsed = {0, 0, NULL}};

void initOrSetCrdt(void) {
    registerMultimasterCommandHandler(sdsnew("sadd"), (multimasterCommandHandler *)&saddOrsetHandler);
    registerMultimasterCommandHandler(sdsnew("srem"), (multimasterCommandHandler *)&sremOrsetHandler);
}
