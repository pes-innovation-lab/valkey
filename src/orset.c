/*
 * Copyright (c) Valkey Contributors
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "orset.h"
#include "endianconv.h"
#include "hashtable.h"
#include "zmalloc.h"

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
    os->comp_key = sdsdup(comp_key);
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
    hashtableIterator *it = NULL;
    hashtableInitIterator(it, ent->tagset, 0);
    void *tag_ptr;
    while (hashtableNext(it, &tag_ptr)) arr[i++] = tag_ptr;
    hashtableReleaseIterator(it);

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
