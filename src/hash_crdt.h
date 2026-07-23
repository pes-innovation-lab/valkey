#ifndef HASHCRDT
#define HASHCRDT

#include "server.h"

typedef struct{
    uint16_t peer_id;
    long long p_val;
    long long n_val;
    hlc hlc_timestamp;
} peer_value;

typedef struct{
    hlc reset_hlc;
    sds base_val;
    list *list_of_peers;
} hash_key_field;


typedef struct {
    multimasterCommandHandler handler;
    hlc parsed_reset_hlc;
} hincrbyCommandHandler;

void initializeHashKeyField(hash_key_field *crdt,hlc *timestamp, char* base_val);
sds evaluateHashKey(hash_key_field *crdt);
peer_value* findPeerByPeerId(hash_key_field *crdt,uint16_t peerid);
peer_value* createNewPeer(uint16_t peerid);
uint16_t getPeerId(sds origin_uuid);
int hsetParse(multimasterCommandHandler *self, sds raw);
robj *hsetSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc);
void hsetResolve(multimasterCommandHandler *self, client *c);
int hincrbyParse(multimasterCommandHandler *self, sds raw);
robj *hincrbySerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc);
void hincrbyResolve(multimasterCommandHandler *self, client *c);
#endif