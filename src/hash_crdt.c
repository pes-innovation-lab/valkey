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
        return crdt->base_val;
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