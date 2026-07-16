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

/* Lookups */

/* Find the exact block fragment containing the targeted offset */
rga_block_t *find_offset(bwrga_t *b, rga_id_t identifier, uint32_t target_offset) {
    rga_block_t *node = NULL;
    hashtableFind(b->base_table, &identifier, (void **)&node);
    while (node != NULL) {
        if (target_offset >= node->offset && target_offset < node->offset + node->length) {
            return node;
        }
        node = node->splitLink;
    }
    return NULL;
}

/* Helper: Finds block containing target visible position (0-indexed) */
static int find_visible_char_pos(bwrga_t *b, uint32_t target_pos, rga_id_t *out_id, uint32_t *out_offset) {
    rga_block_t *cur = b->head;
    uint32_t visible_count = 0;
    while (cur != NULL) {
        if (!cur->is_tombstone) {
            uint32_t block_visible_len = cur->length;
            if (visible_count + block_visible_len > target_pos) {
                uint32_t local_offset = target_pos - visible_count;
                *out_id = rgaIdDup(&cur->identifier);
                *out_offset = cur->offset + local_offset;
                return 1;
            }
            visible_count += block_visible_len;
        }
        cur = cur->nextLink;
    }
    return 0;
}

/* Find predecessor for insert position (requires offset shift of -1) */
int find_predecessor(bwrga_t *b, uint32_t target_pos, rga_id_t *out_id, uint32_t *out_offset) {
    if (target_pos == 0 || b->head == NULL) {
        out_id->ts.wall_time = 0;
        out_id->ts.logical = 0;
        out_id->origin = NULL;
        *out_offset = 0;
        return 1; /* HEAD sentinel */
    }
    return find_visible_char_pos(b, target_pos - 1, out_id, out_offset);
}

/* Find start of delete position (resolves directly to the position itself) */
int find_delete_start(bwrga_t *b, uint32_t target_pos, rga_id_t *out_id, uint32_t *out_offset) {
    return find_visible_char_pos(b, target_pos, out_id, out_offset);
}

/* Mutations */

/* Performs an in-place split of 'node'.
 * Mutates 'node' to be the left piece and returns the newly-allocated right piece. */
rga_block_t *split_at(bwrga_t *b, rga_block_t *node, uint32_t local_pos) {
    if (local_pos == 0 || local_pos >= node->length) {
        return node;
    }
    rga_block_t *right = zmalloc(sizeof(rga_block_t));

    right->identifier.ts = node->identifier.ts;
    right->identifier.origin = node->identifier.origin ? sdsdup(node->identifier.origin) : NULL;
    right->offset = node->offset + local_pos;
    right->length = node->length - local_pos;
    right->is_tombstone = node->is_tombstone;

    right->del_uid.ts = node->del_uid.ts;
    right->del_uid.origin = node->del_uid.origin ? sdsdup(node->del_uid.origin) : NULL;

    /* right's predecessor is the end of the left piece (node, once shrunk
     * below), not the pre-split original's predecessor , needed for
     * bwrgaMerge and anything reconstructing position from parent_id/offset. */
    right->parent_id.ts = node->identifier.ts;
    right->parent_id.origin = node->identifier.origin ? sdsdup(node->identifier.origin) : NULL;
    right->parent_offset = node->offset + local_pos - 1;

    if (node->is_tombstone || node->content == NULL) {
        right->content = NULL;
    } else {
        right->content = zmalloc(right->length + 1);
        memcpy(right->content, node->content + local_pos, right->length);
        right->content[right->length] = '\0';

        char *new_left_content = zmalloc(local_pos + 1);
        memcpy(new_left_content, node->content, local_pos);
        new_left_content[local_pos] = '\0';
        zfree(node->content);
        node->content = new_left_content;
    }

    node->length = local_pos;

    
    right->splitLink = node->splitLink;
    node->splitLink = right;

    /* Document materialized chain updated */
    right->nextLink = node->nextLink;
    node->nextLink = right;

    return right;
}

/* Resolves the SPECIFIC fragment currently covering node's parent_offset
 * within parent_id's lineage. Returns NULL if anchored at HEAD or unresolvable. */
static rga_block_t *resolve_parent_block(bwrga_t *b, const rga_block_t *node) {
    if (node->parent_id.ts.wall_time == 0 && node->parent_id.ts.logical == 0 && node->parent_id.origin == NULL) {
        return NULL; /* anchored directly at HEAD */
    }
    return find_offset(b, node->parent_id, node->parent_offset);
}

/* Walks up node's ancestor chain via resolve_parent_block until it finds the
 * fragment that is a DIRECT child of `parent` (NULL means HEAD). Returns that
 * direct child (maybe node itself), or NULL if node isn't in parent's subtree.*/
static rga_block_t *find_direct_child_ancestor(bwrga_t *b, rga_block_t *node, rga_block_t *parent) {
    rga_block_t *cur = node;
    while (cur != NULL) {
        rga_block_t *cur_parent = resolve_parent_block(b, cur);
        if (cur_parent == parent) return cur;
        cur = cur_parent;
    }
    return NULL;
}

/* Re-runs the survival check for distinct inserts anchored directly at `node`,
 * now that it's tombstoned , covers a delete arriving after an insert already
 * spliced onto that position 
 *
 * Excludes fragments sharing node's identifier , parent block should be `node`
 * and should not be tomstoned */
static void cascade_tombstone(bwrga_t *b, rga_block_t *node) {
    rga_block_t *cur = node->nextLink;
    while (cur != NULL) {
        if (!cur->is_tombstone && !rgaIdKeyCompare(&cur->identifier, &node->identifier) &&
            resolve_parent_block(b, cur) == node) {
            /* Exact HLC tie between insert and delete resolves to tombstoning (favoring delete) */
            if (hlcCompare(&cur->identifier.ts, &node->del_uid.ts) <= 0) {
                cur->is_tombstone = 1;
                if (cur->content) {
                    zfree(cur->content);
                    cur->content = NULL;
                }
                cur->del_uid.ts = node->del_uid.ts;
                cur->del_uid.origin = node->del_uid.origin ? sdsdup(node->del_uid.origin) : NULL;
            }
        }
        cur = cur->nextLink;
    }
}

/* Tombstone every fragment spanning the target range, splitting if boundaries don't align */
void apply_rga_delete(bwrga_t *b, rga_id_t identifier, uint32_t del_offset, uint32_t del_length, rga_id_t del_uid) {
    uint32_t range_end = del_offset + del_length;
    rga_block_t *node = NULL;
    hashtableFind(b->base_table, &identifier, (void **)&node);

    while (node != NULL && node->offset < range_end) {
        uint32_t node_end = node->offset + node->length;

        /* If range starts inside fragment, split it first */
        if (node->offset < del_offset && node_end > del_offset) {
            node = split_at(b, node, del_offset - node->offset);
            node_end = node->offset + node->length;
        }
        /* If range ends inside fragment, split off the tail */
        if (node_end > range_end) {
            split_at(b, node, range_end - node->offset);
            node_end = range_end;
        }

        if (node->offset >= del_offset && node_end <= range_end) {
            if (node->is_tombstone) {
                /* Keep causally more recent delete timestamp */
                if (hlcCompare(&del_uid.ts, &node->del_uid.ts) > 0) {
                    if (node->del_uid.origin) sdsfree(node->del_uid.origin);
                    node->del_uid.ts = del_uid.ts;
                    node->del_uid.origin = del_uid.origin ? sdsdup(del_uid.origin) : NULL;
                    cascade_tombstone(b, node);
                }
            } else {
                node->is_tombstone = 1;
                if (node->content) {
                    zfree(node->content);
                    node->content = NULL;
                }
                node->del_uid.ts = del_uid.ts;
                node->del_uid.origin = del_uid.origin ? sdsdup(del_uid.origin) : NULL;
                cascade_tombstone(b, node);
            }
        }
        node = node->splitLink;
    }
}

/* Insert a new block in the document, handling sibling ordering and survival check */
void apply_rga_insert(bwrga_t *b, rga_id_t new_id, const char *content, uint32_t length, rga_id_t predecessor, uint32_t pred_offset) {
  
    rga_block_t *existing = NULL;
    hashtableFind(b->base_table, &new_id, (void **)&existing);
    if (existing != NULL) {
        return;
    }   

    rga_block_t *new_node = zmalloc(sizeof(rga_block_t));
    new_node->identifier.ts = new_id.ts;
    new_node->identifier.origin = new_id.origin ? sdsdup(new_id.origin) : NULL;
    new_node->offset = 0;
    new_node->length = length;
    new_node->is_tombstone = 0;
    new_node->del_uid.ts.wall_time = 0;
    new_node->del_uid.ts.logical = 0;
    new_node->del_uid.origin = NULL;

    new_node->parent_id.ts = predecessor.ts;
    new_node->parent_id.origin = predecessor.origin ? sdsdup(predecessor.origin) : NULL;
    new_node->parent_offset = pred_offset;

    new_node->content = zmalloc(length + 1);
    memcpy(new_node->content, content, length);
    new_node->content[length] = '\0';
    new_node->nextLink = NULL;
    new_node->splitLink = NULL;

    /* Register in base_table lookup , new_id is always brand new here.
     * new_node itself is the entry; its own 'identifier' field is the key. */
    hashtableAdd(b->base_table, new_node);

    rga_block_t *pred_node = NULL;
    int pred_found = 0;
    int is_head = (predecessor.ts.wall_time == 0 && predecessor.ts.logical == 0 && predecessor.origin == NULL);

    if (!is_head) {
        pred_node = find_offset(b, predecessor, pred_offset);
        if (pred_node != NULL) {
            pred_found = 1;
            uint32_t local_pos = pred_offset - pred_node->offset + 1;
            if (local_pos < pred_node->length) {
                split_at(b, pred_node, local_pos);
            }
        }
    }

    /* Survival Check: exact HLC tie resolves to tombstoning (favoring delete) */
    if (pred_found && pred_node->is_tombstone) {
        if (hlcCompare(&new_node->identifier.ts, &pred_node->del_uid.ts) <= 0) {
            new_node->is_tombstone = 1;
            zfree(new_node->content);
            new_node->content = NULL;
            new_node->del_uid.ts = pred_node->del_uid.ts;
            new_node->del_uid.origin = pred_node->del_uid.origin ? sdsdup(pred_node->del_uid.origin) : NULL;
        }
    }

    /* Deterministic tie-break among concurrent siblings: compare IDs only
     * against direct siblings of pred_node; skip nested descendants
     * unconditionally so new_node can't get spliced into a sibling's subtree. */
    rga_block_t *prev = pred_node;
    rga_block_t *cur = (pred_node == NULL) ? b->head : pred_node->nextLink;

    while (cur != NULL) {
        rga_block_t *direct_child = find_direct_child_ancestor(b, cur, pred_node);
        if (direct_child == NULL) break; /* cur falls outside pred_node's subtree entirely */
        if (direct_child == cur && rgaIdCompare(&cur->identifier, &new_node->identifier) <= 0) {
            break; /* cur is a direct sibling that sorts after new_node */
        }
        prev = cur;
        cur = cur->nextLink;
    }

    if (prev == NULL) {
        new_node->nextLink = b->head;
         b->head = new_node;
    } else {
        new_node->nextLink = prev->nextLink;
        prev->nextLink = new_node;
    }
}


/* Reconstructs an arbitrary fragment (any offset, any tombstone state) of a
 * possibly-already-known identity into b , used only by bwrgaMerge. */
void apply_rga_insert_fragment(bwrga_t *b, rga_id_t identifier, uint32_t offset,
                                const char *content, uint32_t length,
                                int is_tombstone, rga_id_t del_uid,
                                rga_id_t predecessor, uint32_t pred_offset) {
    rga_block_t *new_node = zmalloc(sizeof(rga_block_t));
    new_node->identifier.ts = identifier.ts;
    new_node->identifier.origin = identifier.origin ? sdsdup(identifier.origin) : NULL;
    new_node->offset = offset;
    new_node->length = length;
    new_node->is_tombstone = is_tombstone;

    if (is_tombstone) {
        new_node->content = NULL;
        new_node->del_uid.ts = del_uid.ts;
        new_node->del_uid.origin = del_uid.origin ? sdsdup(del_uid.origin) : NULL;
    } else {
        new_node->content = zmalloc(length + 1);
        memcpy(new_node->content, content, length);
        new_node->content[length] = '\0';
        new_node->del_uid.ts.wall_time = 0;
        new_node->del_uid.ts.logical = 0;
        new_node->del_uid.origin = NULL;
    }

    new_node->parent_id.ts = predecessor.ts;
    new_node->parent_id.origin = predecessor.origin ? sdsdup(predecessor.origin) : NULL;
    new_node->parent_offset = pred_offset;
    new_node->nextLink = NULL;
    new_node->splitLink = NULL;

    /* Register only if this identity is new to b; otherwise splice into the
     * existing splitLink lineage (sorted by offset) so find_offset keeps
     * walking across every fragment of this identity. */
    rga_block_t *existing_base = NULL;
    hashtableFind(b->base_table, &new_node->identifier, (void **)&existing_base);
    if (existing_base == NULL) {
        hashtableAdd(b->base_table, new_node);
    } else {
        rga_block_t *prev = existing_base;
        while (prev->splitLink != NULL && prev->splitLink->offset < new_node->offset) {
            prev = prev->splitLink;
        }
        new_node->splitLink = prev->splitLink;
        prev->splitLink = new_node;
    }

    /* Same predecessor resolution, sibling-ordering, and survival-check
     * logic as apply_rga_insert. */
    rga_block_t *pred_node = NULL;
    int pred_found = 0;
    int is_head = (predecessor.ts.wall_time == 0 && predecessor.ts.logical == 0 && predecessor.origin == NULL);

    if (!is_head) {
        pred_node = find_offset(b, predecessor, pred_offset);
        if (pred_node != NULL) {
            pred_found = 1;
            uint32_t local_pos = pred_offset - pred_node->offset + 1;
            if (local_pos < pred_node->length) {
                split_at(b, pred_node, local_pos);
            }
        }
    }

    if (pred_found && pred_node->is_tombstone && !new_node->is_tombstone) {
        if (hlcCompare(&new_node->identifier.ts, &pred_node->del_uid.ts) <= 0) {
            new_node->is_tombstone = 1;
            if (new_node->content) {
                zfree(new_node->content);
                new_node->content = NULL;
            }
            new_node->del_uid.ts = pred_node->del_uid.ts;
            new_node->del_uid.origin = pred_node->del_uid.origin ? sdsdup(pred_node->del_uid.origin) : NULL;
        }
    }

    // Block placement algorith 

    rga_block_t *prev = pred_node;
    rga_block_t *cur = (pred_node == NULL) ? b->head : pred_node->nextLink;

    while (cur != NULL) {
        rga_block_t *direct_child = find_direct_child_ancestor(b, cur, pred_node);
        if (direct_child == NULL) break; /* cur falls outside pred_node's subtree entirely */
        if (direct_child == cur && rgaIdCompare(&cur->identifier, &new_node->identifier) <= 0) {
            break; /* cur is a direct sibling that sorts after new_node */
        }
        prev = cur;
        cur = cur->nextLink;
    }

    if (prev == NULL) {
        new_node->nextLink = b->head;
        b->head = new_node;
    } else {
        new_node->nextLink = prev->nextLink;
        prev->nextLink = new_node;
    }
}

