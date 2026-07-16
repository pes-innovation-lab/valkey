#ifndef BWRGA_H
#define BWRGA_H

#include "server.h"

/* Unique identifier for an RGA block or operation */
typedef struct rga_id {
    hlc ts;         /* {wall_time, logical} - Hybrid Logical Clock timestamp */
    sds origin;     /* Originating master's node runid/UUID */
} rga_id_t;

/* A fragment representing a contiguous run of characters.
 *
 * Invariants:
 * 1. 'identifier' never changes across splits; it always names the original insertion.
 * 2. 'offset' is relative to the original insertion, not to the current fragment.
 * 3. 'length' survives tombstoning, but 'content' is freed (set to NULL).
 * 4. 'parent_id' and 'parent_offset' store the coordinates of THIS FRAGMENT's actual
 *    predecessor 
 */
typedef struct rga_block {
    rga_id_t identifier;    /* ID of the ORIGINAL inserted block (shared by all split fragments) */
    uint32_t offset;        /* Starting offset of this fragment relative to the original block */
    char *content;          /* Heap-allocated character array (NULL if tombstoned) */
    uint32_t length;        /* Character length (persists even if tombstoned) */
    int is_tombstone;       /* Flag indicating whether this fragment has been deleted */
    rga_id_t del_uid;       /* ID of the delete operation that tombstoned it */

    /* Concurrency and parent-child hierarchy trackers */
    rga_id_t parent_id;     /* Identifier of this FRAGMENT's actual predecessor block */
    uint32_t parent_offset; /* Offset within the predecessor block for this fragment */

    struct rga_block *nextLink;   /* Pointer to the next block in the materialized document layout */
    struct rga_block *splitLink;  /* Pointer to the next sibling fragment of the same original block,
                                    * kept sorted by ascending offset */
} rga_block_t;

/* Represents the overall String CRDT structure */
typedef struct bwrga {
    rga_block_t *head;      /* Head of the materialized nextLink chain */
    hashtable *base_table;  /* Lookup map: rga_id_t -> FIRST-REGISTERED fragment of that ID
                              * (not necessarily offset 0 if that fragment was never seen locally --
                              * see apply_rga_insert_fragment). Entries ARE rga_block_t* directly --
                              * the identifier lives in each block's own 'identifier' field, so no
                              * separate heap-allocated key is needed (see rgaBlockGetIdentifier). */
} bwrga_t;

bwrga_t *bwrgaNew(void);
void bwrgaFree(bwrga_t *bwrga);

/* Helper ID allocation and comparison functions */
rga_id_t rgaIdNew(hlc ts, const char *origin);
void rgaIdFree(rga_id_t *id);
rga_id_t rgaIdDup(const rga_id_t *id);
int rgaIdCompare(const rga_id_t *a, const rga_id_t *b);

/* Lookup functions */
rga_block_t *find_offset(bwrga_t *b, rga_id_t identifier, uint32_t target_offset);
int find_predecessor(bwrga_t *b, uint32_t target_pos, rga_id_t *out_id, uint32_t *out_offset);
int find_delete_start(bwrga_t *b, uint32_t target_pos, rga_id_t *out_id, uint32_t *out_offset);

/* Core mutations */
rga_block_t *split_at(bwrga_t *b, rga_block_t *node, uint32_t local_pos);
void apply_rga_delete(bwrga_t *b, rga_id_t identifier, uint32_t del_offset, uint32_t del_length, rga_id_t del_uid);
void apply_rga_insert(bwrga_t *b, rga_id_t new_id, const char *content, uint32_t length, rga_id_t predecessor, uint32_t pred_offset);

/* Reconstructs an ARBITRARY fragment (any offset, any tombstone state)*/
void apply_rga_insert_fragment(bwrga_t *b, rga_id_t identifier, uint32_t offset,
                                const char *content, uint32_t length,
                                int is_tombstone, rga_id_t del_uid,
                                rga_id_t predecessor, uint32_t pred_offset);

                                
#endif