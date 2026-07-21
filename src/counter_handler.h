#ifndef COUNTER_HANDLER_H
#define COUNTER_HANDLER_H

#include "server.h"

/* Attaches a simple multimasterCommandHandler to incr, decr, incrby and
 * decrby. These commands are commutative, so replaying the plain command
 * gives the correct CRDT merge. That is enough to skip the RMW rewrite
 * and the HLC freshness drop in replication.c for these commands. */
void counterHandlerInit(void);

#endif
