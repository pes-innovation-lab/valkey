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
    char *base_val;
    list *list_of_peers;
} hash_key_field;

void initializeHashKeyField(hash_key_field *crdt,hlc *timestamp, char* base_val);


#endif