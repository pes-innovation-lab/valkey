/* Simple multimasterCommandHandler for INCR, DECR, INCRBY and DECRBY.
 * Attaching any handler here makes getMultimasterWhitelistedHandler
 * return non NULL, which is what the checks in replication.c need. The
 * plain command already gives the correct merge since a delta is commutative. */

#include "counter_handler.h"

static robj *counterSerialize(multimasterCommandHandler *self, struct serverCommand *cmd, robj **argv, int argc) {
    UNUSED(self);
    UNUSED(cmd);
    UNUSED(argv);
    UNUSED(argc);
    /* Nothing extra to send. The command itself already carries the
     * delta, and running it again on the other side gives the right result. */
    return createStringObject(RREPLAY_META_NONE, strlen(RREPLAY_META_NONE));
}

static int counterParse(multimasterCommandHandler *self, sds raw) {
    UNUSED(self);
    UNUSED(raw);
    /* rreplayMultimasterMetadataParse() already handles the "none" case
     * before this runs, and counterSerialize() never sends anything else.
     * If we get here the metadata is unexpected, so we reject it. */
    return C_ERR;
}

static multimasterCommandHandler counterHandler = {
    .parse = counterParse,
    .serialize = counterSerialize,
};

/* Attaches the handler straight to the command table instead of using
 * registerMultimasterCommandHandler(), which only works if the command
 * is already in the whitelist. See bwrgaAttachHandler for the same reason. */
static void counterAttachHandler(const char *name) {
    sds cmd_name = sdsnew(name);
    struct serverCommand *cmd = lookupCommandBySds(cmd_name);
    sdsfree(cmd_name);
    if (cmd) cmd->command_handler = &counterHandler;
}

void counterHandlerInit(void) {
    counterAttachHandler("incr");
    counterAttachHandler("decr");
    counterAttachHandler("incrby");
    counterAttachHandler("decrby");
}
