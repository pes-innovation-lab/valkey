#include "bwrga.h"
#include <string.h>

/* Hashtable type definitions for base_table */

uint64_t rgaIdHashFunction(const void *key) {
    const rga_id_t *id = key;
    uint64_t h = (uint64_t)id->ts.wall_time;
    h ^= (uint64_t)id->ts.logical + 0x9e3779b9 + (h << 6) + (h >> 2);
    if (id->origin) {
        h ^= dictGenHashFunction(id->origin, sdslen(id->origin));
    }
    return h;
}

int rgaIdKeyCompare(const void *key1, const void *key2) {
    const rga_id_t *id1 = key1;
    const rga_id_t *id2 = key2;
    if (id1->ts.wall_time != id2->ts.wall_time) return 0;
    if (id1->ts.logical != id2->ts.logical) return 0;
    if (id1->origin == NULL || id2->origin == NULL) {
        return id1->origin == id2->origin;
    }
    return sdscmp(id1->origin, id2->origin) == 0;
}


const void *rgaBlockGetIdentifier(const void *entry) {
    const rga_block_t *block = entry;
    return &block->identifier;
}

hashtableType rgaBaseTableHashType = {
    .entryGetKey = rgaBlockGetIdentifier,
    .hashFunction = rgaIdHashFunction,
    .keyCompare = rgaIdKeyCompare,

};

