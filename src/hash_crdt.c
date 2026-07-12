#include "server.h"
#include "hash_crdt.h"

void initializeHashKeyField(hash_key_field *crdt,hlc *timestamp, char* base_val){
    crdt->reset_hlc.wall_time = timestamp->wall_time;
    crdt->reset_hlc.logical = timestamp->logical;
    crdt->base_val = strdup(base_val);

    // listIter check_li;
    // listNode *check_ln;
    // listRewind(crdt->list_of_peers, &check_li);
    // while ((check_ln = listNext(&check_li)) != NULL) {
    //     peer_value *peer = listNodeValue(check_ln);
    //     if (peer->peer_id == id){
    //         return;
    //     }
    // }

    // peer_value *newpeer = zmalloc(sizeof(peer_value));
    // newpeer->peer_id = id;
    // newpeer->hlc_timestamp.wall_time = timestamp->wall_time;
    // newpeer->hlc_timestamp.logical = timestamp->logical;
    // newpeer->p_val = 0;
    // newpeer->n_val = 0;
    // listAddNodeTail(crdt->list_of_peers,newpeer);
}