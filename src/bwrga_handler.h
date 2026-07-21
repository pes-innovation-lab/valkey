#ifndef BWRGA_HANDLER_H
#define BWRGA_HANDLER_H

#include "server.h"
#include "bwrga.h"

/* Wraps multimasterCommandHandler as the first field so this struct can
 * be used as one. There is no resolve function: append, setrange and set
 * call bwrgaApplyAppend, bwrgaApplySetrange and bwrgaApplySet from their
 * own proc, so call() still handles dirty tracking and propagation. */

/* The remaining fields hold scratch state for one call. parse fills them
 * for a replay, and the local write path fills them for serialize to
 * read right after. has_pending_replay marks real parsed data, since a
 * plain replicated write with no metadata must not reuse old values. */
typedef struct bwrgaCommandHandler {
    multimasterCommandHandler base;

    int has_pending_replay;
    rga_id_t id;            /* the new block's own identity */
    rga_id_t predecessor;
    uint32_t pred_offset;
    rga_id_t del_target_id; /* SETRANGE/SET's delete target identity */
    uint32_t del_offset;
    uint32_t del_length;
} bwrgaCommandHandler;

/* Attaches the BWRGA handler to append, setrange and set. Must run
 * after the command table is filled, for example from initServer. */
void bwrgaHandlerInit(void);

/* True if cmd is currently set up for BWRGA. Called at the start of
 * append, setrange and set in t_string.c to pick the CRDT path. */
int bwrgaIsWhitelisted(struct serverCommand *cmd);

/* Applies the already resolved CRDT change for append, setrange or set,
 * including create or migrate, the RGA change itself, and the usual
 * notify and reply steps. Runs inside call(), not instead of it. */
void bwrgaApplyAppend(client *c);
void bwrgaApplySetrange(client *c);
void bwrgaApplySet(client *c);

#endif
