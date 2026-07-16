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

bwrga_t *bwrgaNew(void) {
    bwrga_t *b = zmalloc(sizeof(bwrga_t));
    b->head = NULL;
    b->base_table = hashtableCreate(&rgaBaseTableHashType);
    return b;
}

void bwrgaFree(bwrga_t *b) {
    if (b == NULL) return;

    rga_block_t *cur = b->head;
    while (cur != NULL) {
        rga_block_t *next = cur->nextLink;
        if (cur->identifier.origin) sdsfree(cur->identifier.origin);
        if (cur->del_uid.origin) sdsfree(cur->del_uid.origin);
        if (cur->parent_id.origin) sdsfree(cur->parent_id.origin);
        if (cur->content) zfree(cur->content);
        zfree(cur);
        cur = next;
    }

    hashtableRelease(b->base_table);
    zfree(b);
}

/* Helper ID Functions */

rga_id_t rgaIdNew(hlc ts, const char *origin) {
    rga_id_t id;
    id.ts = ts;
    id.origin = origin ? sdsnew(origin) : NULL;
    return id;
}

void rgaIdFree(rga_id_t *id) {
    if (id && id->origin) {
        sdsfree(id->origin);
        id->origin = NULL;
    }
}

rga_id_t rgaIdDup(const rga_id_t *id) {
    rga_id_t dup;
    dup.ts = id->ts;
    dup.origin = id->origin ? sdsdup(id->origin) : NULL;
    return dup;
}

int rgaIdCompare(const rga_id_t *a, const rga_id_t *b) {
    int cmp = hlcCompare(&a->ts, &b->ts);
    if (cmp != 0) return cmp;
    if (a->origin == NULL || b->origin == NULL) {
        if (a->origin == b->origin) return 0;
        return a->origin ? 1 : -1;
    }
    return sdscmp(a->origin, b->origin);
}
