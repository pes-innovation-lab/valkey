#include "server.h"
#include "hash_crdt.h"

void initializeHashKeyField(hash_key_field *crdt,hlc *timestamp, char* base_val){
    crdt->reset_hlc.wall_time = timestamp->wall_time;
    crdt->reset_hlc.logical = timestamp->logical;
    crdt->base_val = sdsnew(base_val);
    crdt->list_of_peers = listCreate();

    // peer_value *newpeer = zmalloc(sizeof(peer_value));
    // newpeer->peer_id = id;
    // newpeer->hlc_timestamp.wall_time = timestamp->wall_time;
    // newpeer->hlc_timestamp.logical = timestamp->logical;
    // newpeer->p_val = 0;
    // newpeer->n_val = 0;
    // listAddNodeTail(crdt->list_of_peers,newpeer);
}


sds evaluateHashKey(hash_key_field *crdt){
    long long currentvalue;
    if(string2ll(crdt->base_val,sdslen(crdt->base_val),&currentvalue) == 0){
        return sdsdup(crdt->base_val);
    }

    listIter check_li;
    listNode *check_ln;
    listRewind(crdt->list_of_peers, &check_li);
    while ((check_ln = listNext(&check_li)) != NULL) {
        peer_value *peer = listNodeValue(check_ln);
        if(hlcCompare(&peer->hlc_timestamp,&crdt->reset_hlc)>=0){
            currentvalue = currentvalue+peer->p_val+peer->n_val;
        }
        //currentvalue = currentvalue+peer->p_val+peer->n_val;
    }
    return sdsfromlonglong(currentvalue);
}


peer_value* findPeerByPeerId(hash_key_field *crdt,uint16_t peerid){
    listIter check_li;
    listNode *check_ln;
    listRewind(crdt->list_of_peers, &check_li);
    while ((check_ln = listNext(&check_li)) != NULL) {
        peer_value *peer = listNodeValue(check_ln);
        if (peer->peer_id == peerid){
            return peer;
        }
    }
    return NULL;
}

peer_value* createNewPeer(uint16_t peerid){

    peer_value *newpeer = zmalloc(sizeof(peer_value));
    newpeer->peer_id = peerid;
    newpeer->p_val = 0;
    newpeer->n_val = 0;
    return newpeer;
}

uint16_t getPeerId(sds origin_uuid){
    uint16_t *peerid = dictFetchValue(server.peer_registry,origin_uuid);
    if (!peerid){
        peerid = zmalloc(sizeof(int));
        *peerid = server.next_peer_id++;
        dictAdd(server.peer_registry,sdsdup(origin_uuid),(void*)peerid);
    }
    return *peerid;
}

/* Stub parse handler for HSET. Currently no extra metadata is parsed. */
int hsetParse(multimasterCommandHandler *self, sds raw) {
    UNUSED(self);
    UNUSED(raw);
    return C_OK;
}

/* Stub serialize handler for HSET. Returns the "none" sentinel. */
robj *hsetSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    UNUSED(self);
    UNUSED(cmd);
    UNUSED(argv);
    UNUSED(argc);
    return createStringObject("none", 4);
}

/* Resolve function for HSET.
 *
 * Performs subkey-level LWW conflict resolution before the actual hsetCommand
 * writes to the database. For each field in the HSET command:
 *   - Look up the CRDT metadata for that field.
 *   - If the incoming HLC is older than the stored reset_hlc, drop that field
 *     (the local value wins).
 *   - Otherwise, update the CRDT metadata with the new base_val and reset_hlc,
 *     compute the merged value via evaluateHashKey, and rewrite the client argv
 *     to carry the resolved value.
 *
 * After resolution, call() is invoked so the clean hsetCommand writes the
 * winning values to the database. */
void hsetResolve(multimasterCommandHandler *self, client *c) {
    UNUSED(self);
    hlcNextLocalClock();
    hlc *current_hlc = server.current_rreplay_hlc;
    if (!current_hlc) {
        
        current_hlc = &server.hlc_clock;
    }

    sds top_level_key = objectGetVal(c->argv[1]);

    /* We build a new argv that only contains the winning fields.
     * Worst case: all fields win, so allocate the same size as the original. */
    int new_argc_cap = c->argc;
    robj **new_argv = zmalloc(sizeof(robj *) * new_argc_cap);
    int new_argc = 2; /* argv[0] = command name, argv[1] = key */
    new_argv[0] = c->argv[0];
    incrRefCount(c->argv[0]);
    new_argv[1] = c->argv[1];
    incrRefCount(c->argv[1]);

    for (int i = 2; i < c->argc; i += 2) {
        sds field = objectGetVal(c->argv[i]);
        sds hashkey = sdscatfmt(sdsempty(), "%S:%S", top_level_key, field);

        hash_key_field *hashcrdt = dictFetchValue(server.hash_crdt_metadata, hashkey);

        if (hashcrdt) {
            /* Field already has CRDT metadata. Apply LWW. */
            if (hlcCompare(current_hlc, &hashcrdt->reset_hlc) >= 0) {
                /* Incoming write wins (or is equal). Update metadata. */
                hashcrdt->reset_hlc.wall_time = current_hlc->wall_time;
                hashcrdt->reset_hlc.logical = current_hlc->logical;
                sdsfree(hashcrdt->base_val);
                hashcrdt->base_val = sdsdup(objectGetVal(c->argv[i + 1]));
            } else {
                /* Local value wins. Drop this field from the command. */
                sdsfree(hashkey);
                continue;
            }
        } else {
            /* First time seeing this field. Create fresh CRDT metadata. */
            hashcrdt = zmalloc(sizeof(hash_key_field));
            initializeHashKeyField(hashcrdt, current_hlc, objectGetVal(c->argv[i + 1]));
            dictAdd(server.hash_crdt_metadata, hashkey, hashcrdt);
            hashkey = NULL; /* dictAdd took ownership of the key */
        }

        /* Compute the merged value (base_val + surviving increments). */
        sds resolved_val = evaluateHashKey(hashcrdt);

        /* Add the field and resolved value to the new argv. */
        new_argv[new_argc] = c->argv[i];
        incrRefCount(c->argv[i]);
        new_argc++;
        new_argv[new_argc] = createStringObject(resolved_val, sdslen(resolved_val));
        new_argc++;

        sdsfree(resolved_val);
        if (hashkey) sdsfree(hashkey);
    }

    /* If all fields were dropped by LWW, there is nothing to write.
     * Reply to the client and clean up. */
    if (new_argc <= 2) {
        for (int j = 0; j < new_argc; j++) decrRefCount(new_argv[j]);
        zfree(new_argv);
        /* HMSET (deprecated) and HSET return value is different. */
        char *cmdname = objectGetVal(c->argv[0]);
        if (cmdname[1] == 's' || cmdname[1] == 'S') {
            addReplyLongLong(c, 0);
        } else {
            addReply(c, shared.ok);
        }
        return;
    }

    /* Replace the client's argv with the resolved one. */
    /* Free old argv entries (the originals). */
    for (int j = 0; j < c->argc; j++) decrRefCount(c->argv[j]);
    zfree(c->argv);

    c->argv = new_argv;
    c->argc = new_argc;
    c->argv_len = new_argc;

    /* Determine the right call() flags based on context.
     * If current_rreplay_hlc is set, we are inside rreplayCommand (replicated path). */
    int flags = server.current_rreplay_hlc ? CMD_CALL_PROPAGATE_AOF : CMD_CALL_FULL;
    call(c, flags);
}

/* Stub parse handler for HINCRBY. Currently no extra metadata is parsed. */
int hincrbyParse(multimasterCommandHandler *self, sds raw) {
    UNUSED(self);
    UNUSED(raw);
    return C_OK;
}

/* Stub serialize handler for HINCRBY. Returns the "none" sentinel. */
robj *hincrbySerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    UNUSED(self);
    UNUSED(cmd);
    UNUSED(argv);
    UNUSED(argc);
    return createStringObject("none", 4);
}

void hincrbyResolve(multimasterCommandHandler *self, client *c){
    UNUSED(self);
    long long incr;
    getLongLongFromObjectOrReply(c, c->argv[3], &incr, NULL);

    sds top_level_key = objectGetVal(c->argv[1]);
    sds hashkey = sdscatfmt(sdsempty(),"%S:%S",top_level_key,objectGetVal(c->argv[2]));
    /* indexes the crdt dictionary to find the respective crdt struct. */
    hash_key_field *hashcrdt = dictFetchValue(server.hash_crdt_metadata,hashkey);
    hlc *current_hlc = server.current_rreplay_hlc;
    if (!current_hlc){
        current_hlc = &server.hlc_clock;
    }
    sds origin_uuid = server.incoming_uuid;
    if(!origin_uuid){
        origin_uuid = sdsnew(server.runid);
    }
    uint16_t target_peer_id = getPeerId(origin_uuid);
    peer_value *target_peer = findPeerByPeerId(hashcrdt,target_peer_id);
    if(!target_peer){
        target_peer = createNewPeer(target_peer_id);
        listAddNodeTail(hashcrdt->list_of_peers,target_peer);
    }

    if(incr>=0)
    target_peer->p_val+=incr;
    else
    target_peer->n_val+=incr;

    target_peer->hlc_timestamp.logical = current_hlc->logical;
    target_peer->hlc_timestamp.wall_time = current_hlc->wall_time;

    if(origin_uuid != server.incoming_uuid)
    sdsfree(origin_uuid);

    sds new = evaluateHashKey(hashcrdt);
    long long value;
    string2ll(new,sdslen(new),&value);
    long long pre_increment_val = value-incr;

    robj *o = hashTypeLookupWriteOrCreate(c, c->argv[1]);
    bool expired;
    hashTypeSet(o, objectGetVal(c->argv[2]), sdsfromlonglong(pre_increment_val), 
                EXPIRY_NONE, HASH_SET_TAKE_VALUE, &expired);

    int flags = server.current_rreplay_hlc ? CMD_CALL_PROPAGATE_AOF : CMD_CALL_FULL;
    call(c, flags);
}