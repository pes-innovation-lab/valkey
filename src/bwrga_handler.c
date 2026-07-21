/* BWRGA's multimasterCommandHandler setup. Sets parse and serialize for
 * append, setrange and set, plus the apply functions those commands call
 * from their own proc. There is no resolve function, so call() still
 * handles dirty tracking, notifications and replication as usual. */

#include "bwrga_handler.h"

/* Forward declaration. The real handler is defined near the end of this
 * file, but the apply functions above need to point at it early. */
static bwrgaCommandHandler bwrgaHandler;

/* Mirrors hlcNextLocalClock() from replication.c, which is static there
 * and cannot be reused directly. Moves the HLC clock forward and keeps
 * its drift correction. Keep this in sync by hand if that one changes. */
static hlc bwrgaNextLocalClock(void) {
    uint64_t pt = ustime();
    if (server.hlc_max_clock_drift > 0 &&
        server.hlc_clock.wall_time > pt + (uint64_t)server.hlc_max_clock_drift) {
        serverLog(LL_WARNING,
                  "HLC wall time drifted %.3f ms ahead of physical clock; resetting to physical time (hlc self-stabilization).",
                  (double)(server.hlc_clock.wall_time - pt) / 1000.0);
        server.hlc_clock.wall_time = pt;
        server.hlc_clock.logical = 0;
    } else {
        if (pt > server.hlc_clock.wall_time) {
            server.hlc_clock.wall_time = pt;
            server.hlc_clock.logical = 0;
        } else {
            server.hlc_clock.logical++;
        }
    }
    return server.hlc_clock;
}

/* The HEAD identity: zero timestamp, no origin, meaning the very start
 * of the document. Matches what apply_rga_insert checks for. */
static rga_id_t bwrgaHeadId(void) {
    rga_id_t id;
    id.ts.wall_time = 0;
    id.ts.logical = 0;
    id.origin = NULL;
    return id;
}
 
/* A fixed identity used only to seed migration of an old plain string
 * into a new BWRGA value. Not based on this node's clock or id, so two
 * peers migrating the same value on their own still agree on it. */
static rga_id_t bwrgaMigrationSeedId(void) {
    hlc ts;
    ts.wall_time = 0;
    ts.logical = 0;
    return rgaIdNew(ts, "__bwrga_seed__");
}

/* Looks up key for writing and returns its bwrga_t value, owned by the
 * database. Creates an empty one if missing, or migrates an existing
 * plain string into one on its first CRDT touch. */
static bwrga_t *bwrgaGetOrCreateForWrite(client *c, robj *key) {
    robj *o = lookupKeyWrite(c->db, key);
    if (o == NULL) {
        bwrga_t *b = bwrgaNew();
        robj *new_o = createBwrgaObject(b);
        dbAdd(c->db, key, &new_o);
        return b;
    }
    if (o->encoding == OBJ_ENCODING_BWRGA) {
        return objectGetVal(o);
    }

    robj *decoded = getDecodedObject(o);
    sds existing = objectGetVal(decoded);
    bwrga_t *b = bwrgaNew();
    if (sdslen(existing) > 0) {
        rga_id_t seed = bwrgaMigrationSeedId();
        rga_id_t head = bwrgaHeadId();
        apply_rga_insert(b, seed, existing, sdslen(existing), head, 0);
        rgaIdFree(&seed);
    }
    decrRefCount(decoded);
    robj *new_o = createBwrgaObject(b);
    dbReplaceValue(c->db, key, &new_o);
    return b;
}

/* Clears every scratch field: frees owned strings and zeroes each id,
 * offset and the delete range. Run before refilling so an old cycle
 * cannot leak memory or leave stale data for the next frame. */
static void bwrgaResetScratch(bwrgaCommandHandler *h) {
    rgaIdFree(&h->id);
    rgaIdFree(&h->predecessor);
    rgaIdFree(&h->del_target_id);
    h->id = bwrgaHeadId();
    h->predecessor = bwrgaHeadId();
    h->del_target_id = bwrgaHeadId();
    h->pred_offset = 0;
    h->del_offset = 0;
    h->del_length = 0;
    h->has_pending_replay = 0;
}

/* Rejects append or setrange on a key that is really an integer counter
 * (from incr or decr). Without this check, two nodes could migrate the
 * same counter into a BWRGA value with different content but the same
 * seed id, and one side's write would be silently dropped. */
static int bwrgaRejectIfCounter(client *c, robj *key) {
    robj *existing = lookupKeyWrite(c->db, key);
    if (existing && existing->encoding == OBJ_ENCODING_INT) {
        addReplyError(c, "value is an integer counter and cannot be used as a BWRGA string");
        return 1;
    }
    return 0;
}

/* Shared replay path for setrange and set: applies the delete range
 * first if there is one, then the insert. append does not use this,
 * since append frames never carry a delete range. */
static void bwrgaApplyReplayFrame(client *c, sds content, char *event) {
    bwrgaCommandHandler *h = &bwrgaHandler;
    robj *key = c->argv[1];
    bwrga_t *b = bwrgaGetOrCreateForWrite(c, key);

    if (h->del_length > 0) {
        apply_rga_delete(b, h->del_target_id, h->del_offset, h->del_length, h->id);
    }
    apply_rga_insert(b, h->id, content, sdslen(content), h->predecessor, h->pred_offset);

    signalModifiedKey(c, c->db, key);
    notifyKeyspaceEvent(NOTIFY_STRING, event, key, c->db->id);
    server.dirty++;
}

/* Called from append, setrange and set once they decide a key belongs
 * to BWRGA. These run inside call()'s proc, so dirty tracking and
 * replication still work. Each one still does its own notify, dirty
 * and reply, since call() cannot do that for a type it cannot read.
 *
 * Whether to trust h's coordinates or compute fresh ones depends on
 * h->has_pending_replay. See the struct comment in bwrga_handler.h. */
void bwrgaApplyAppend(client *c) {
    bwrgaCommandHandler *h = &bwrgaHandler;
    robj *key = c->argv[1];
    sds content = objectGetVal(c->argv[2]); /* "append" is an argument, so always an sds */
    int is_local_origin = !h->has_pending_replay;
    h->has_pending_replay = 0;

    if (is_local_origin && bwrgaRejectIfCounter(c, key)) return;

    bwrga_t *b = bwrgaGetOrCreateForWrite(c, key);

    if (is_local_origin) {
        rga_id_t predecessor;
        uint32_t pred_offset;
        find_predecessor(b, bwrgaVisibleLength(b), &predecessor, &pred_offset);

        rga_id_t new_id = rgaIdNew(bwrgaNextLocalClock(), server.runid);
        apply_rga_insert(b, new_id, content, sdslen(content), predecessor, pred_offset);

        /* Save what we just picked. serialize runs right after this
         * proc returns, during call()'s own propagation step. */
        bwrgaResetScratch(h);
        h->id = new_id;
        h->predecessor = predecessor;
        h->pred_offset = pred_offset;
    } else {
        apply_rga_insert(b, h->id, content, sdslen(content), h->predecessor, h->pred_offset);
    }

    signalModifiedKey(c, c->db, key);
    notifyKeyspaceEvent(NOTIFY_STRING, "append", key, c->db->id);
    server.dirty++;
    addReplyLongLong(c, bwrgaVisibleLength(b));
}

/* See bwrgaApplyAppend for the general shape. Setrange past the current
 * end is not handled yet, only offsets inside the current value. */
void bwrgaApplySetrange(client *c) {
    bwrgaCommandHandler *h = &bwrgaHandler;
    int is_local_origin = !h->has_pending_replay;
    h->has_pending_replay = 0;
    robj *key = c->argv[1];
    sds value = objectGetVal(c->argv[3]);

    if (is_local_origin) {
        if (bwrgaRejectIfCounter(c, key)) return;

        long long offset;
        if (getLongLongFromObjectOrReply(c, c->argv[2], &offset, NULL) != C_OK) return;
        if (offset < 0) {
            addReplyError(c, "offset is out of range");
            return;
        }

        bwrga_t *b = bwrgaGetOrCreateForWrite(c, key);
        uint32_t visible_len = bwrgaVisibleLength(b);

        if ((uint64_t)offset > visible_len) {
            addReplyError(c, "SETRANGE past the end of a BWRGA value is not yet supported");
            return;
        }

        rga_id_t predecessor;
        uint32_t pred_offset;
        find_predecessor(b, (uint32_t)offset, &predecessor, &pred_offset);

        int has_delete = ((uint32_t)offset < visible_len);
        rga_id_t del_target;
        uint32_t del_off = 0, del_length = 0;
        if (has_delete) {
            find_delete_start(b, (uint32_t)offset, &del_target, &del_off);
            uint32_t max_delete = visible_len - (uint32_t)offset;
            del_length = (uint32_t)sdslen(value) < max_delete ? (uint32_t)sdslen(value) : max_delete;
        }

        rga_id_t new_id = rgaIdNew(bwrgaNextLocalClock(), server.runid);

        if (has_delete && del_length > 0) {
            apply_rga_delete(b, del_target, del_off, del_length, new_id);
        }
        apply_rga_insert(b, new_id, value, sdslen(value), predecessor, pred_offset);

        bwrgaResetScratch(h);
        h->id = new_id;
        h->predecessor = predecessor;
        h->pred_offset = pred_offset;
        if (has_delete && del_length > 0) {
            h->del_target_id = del_target;
            h->del_offset = del_off;
            h->del_length = del_length;
        } else if (has_delete) {
            rgaIdFree(&del_target); /* computed but unused (no actual overlap) */
        }

        signalModifiedKey(c, c->db, key);
        notifyKeyspaceEvent(NOTIFY_STRING, "setrange", key, c->db->id);
        server.dirty++;
        addReplyLongLong(c, bwrgaVisibleLength(b));
        return;
    }

    bwrgaApplyReplayFrame(c, value, "setrange");
}

/* See bwrgaApplyAppend for the general shape. A full SET must tombstone
 * the old content instead of dropping it, so a concurrent insert
 * anchored there still resolves correctly. Options like EX or NX and
 * values with more than one live identity are not supported yet. */
void bwrgaApplySet(client *c) {
    bwrgaCommandHandler *h = &bwrgaHandler;
    int is_local_origin = !h->has_pending_replay;
    h->has_pending_replay = 0;
    robj *key = c->argv[1];
    sds content = objectGetVal(c->argv[2]);

    if (is_local_origin) {
        if (c->argc > 3) {
            addReplyError(c, "SET with options on a BWRGA value is not yet supported");
            return;
        }

        bwrga_t *b = bwrgaGetOrCreateForWrite(c, key);

        rga_id_t del_id;
        uint32_t del_off, del_len;
        if (!bwrgaSingleLiveIdentityRange(b, &del_id, &del_off, &del_len)) {
            addReplyError(c, "SET on a BWRGA value with multiple distinct live fragments is not yet supported");
            return;
        }

        rga_id_t new_id = rgaIdNew(bwrgaNextLocalClock(), server.runid);
        if (del_len > 0) {
            apply_rga_delete(b, del_id, del_off, del_len, new_id);
        }
        apply_rga_insert(b, new_id, content, sdslen(content), bwrgaHeadId(), 0);

        bwrgaResetScratch(h);
        h->id = new_id;
        /* predecessor stays the HEAD identity ResetScratch just set. */
        if (del_len > 0) {
            h->del_target_id = del_id; /* ownership transferred from bwrgaSingleLiveIdentityRange */
            h->del_offset = del_off;
            h->del_length = del_len;
        }

        signalModifiedKey(c, c->db, key);
        notifyKeyspaceEvent(NOTIFY_STRING, "set", key, c->db->id);
        server.dirty++;
        addReply(c, shared.ok);
        return;
    }

    bwrgaApplyReplayFrame(c, content, "set");
}

static int bwrgaParse(multimasterCommandHandler *self, sds raw) {
    bwrgaCommandHandler *h = (bwrgaCommandHandler *)self;

    /* rreplayMultimasterMetadataParse() already handles the "none" case,
     * and append, setrange and set are the only commands that send
     * anything else, so we can assume this format without checking
     * the command type here (serialize still has to check it). */
    unsigned long long id_wall, id_logical, pred_wall, pred_logical;
    unsigned pred_offset;
    char id_origin[64], pred_origin[64];

    int n = sscanf(raw, "id=%llu:%llu:%63[^;];pred=%llu:%llu:%63[^:]:%u",
                   &id_wall, &id_logical, id_origin, &pred_wall, &pred_logical, pred_origin, &pred_offset);
    if (n != 7) return C_ERR;

    bwrgaResetScratch(h); /* also zeroes the delete range for frames with no delete */
    h->id.ts.wall_time = id_wall;
    h->id.ts.logical = id_logical;
    h->id.origin = strcmp(id_origin, "-") == 0 ? NULL : sdsnew(id_origin);
    h->predecessor.ts.wall_time = pred_wall;
    h->predecessor.ts.logical = pred_logical;
    h->predecessor.origin = strcmp(pred_origin, "-") == 0 ? NULL : sdsnew(pred_origin);
    h->pred_offset = pred_offset;

    /* setrange and set frames also carry a delete range. append frames
     * do not, so no delid here just means there is nothing to delete. */
    char *del_part = strstr(raw, ";delid=");
    if (del_part) {
        unsigned long long del_wall, del_logical;
        unsigned del_offset, del_length;
        char del_origin[64];
        int dn = sscanf(del_part, ";delid=%llu:%llu:%63[^;];deloff=%u;dellen=%u",
                        &del_wall, &del_logical, del_origin, &del_offset, &del_length);
        if (dn != 5) return C_ERR;
        h->del_target_id.ts.wall_time = del_wall;
        h->del_target_id.ts.logical = del_logical;
        h->del_target_id.origin = strcmp(del_origin, "-") == 0 ? NULL : sdsnew(del_origin);
        h->del_offset = del_offset;
        h->del_length = del_length;
    }

    h->has_pending_replay = 1;
    return C_OK;
}

static robj *bwrgaSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    bwrgaCommandHandler *h = (bwrgaCommandHandler *)self;
    UNUSED(argv);
    UNUSED(argc);

    /* The wire format is the same for each command: an id and predecessor
     * pair plus an optional delete range. We check cmd here, not just h,
     * since this runs for every whitelisted command, not only ones that
     * touched h. */
    if (cmd->proc == appendCommand || cmd->proc == setrangeCommand || cmd->proc == setCommand) {
        char buf[400];
        int len = snprintf(buf, sizeof(buf), "id=%llu:%llu:%s;pred=%llu:%llu:%s:%u",
                            (unsigned long long)h->id.ts.wall_time,
                            (unsigned long long)h->id.ts.logical,
                            h->id.origin ? h->id.origin : "-",
                            (unsigned long long)h->predecessor.ts.wall_time,
                            (unsigned long long)h->predecessor.ts.logical,
                            h->predecessor.origin ? h->predecessor.origin : "-",
                            h->pred_offset);
        if (h->del_length > 0) {
            len += snprintf(buf + len, sizeof(buf) - len, ";delid=%llu:%llu:%s;deloff=%u;dellen=%u",
                             (unsigned long long)h->del_target_id.ts.wall_time,
                             (unsigned long long)h->del_target_id.ts.logical,
                             h->del_target_id.origin ? h->del_target_id.origin : "-",
                             h->del_offset, h->del_length);
        }
        return createStringObject(buf, len);
    }

    return createStringObject(RREPLAY_META_NONE, strlen(RREPLAY_META_NONE));
}

/* Whether append, setrange or set should use the BWRGA path. Only checks
 * the whitelist, not the key's encoding, so an existing BWRGA key removed
 * from the whitelist becomes invisible to this check. Kept cheap since
 * it runs on every append, setrange and set call. */
int bwrgaIsWhitelisted(struct serverCommand *cmd) {
    return getMultimasterWhitelistedHandler(cmd) == &bwrgaHandler.base;
}

static bwrgaCommandHandler bwrgaHandler = {
    .base = {
        .parse = bwrgaParse,
        .serialize = bwrgaSerialize,
    },
};

/* Attaches the handler straight to the command table instead of using
 * registerMultimasterCommandHandler(), since that only works if the
 * command is already in the whitelist at this point. */
static void bwrgaAttachHandler(const char *name) {
    sds cmd_name = sdsnew(name);
    struct serverCommand *cmd = lookupCommandBySds(cmd_name);
    sdsfree(cmd_name);
    if (cmd) cmd->command_handler = &bwrgaHandler.base;
}

void bwrgaHandlerInit(void) {
    bwrgaAttachHandler("append");
    bwrgaAttachHandler("setrange");
    bwrgaAttachHandler("set");
}
