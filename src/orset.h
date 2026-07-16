#ifndef ORSET_H
#define ORSET_H

#include "server.h"
#include "sds.h"
#include "hashtable.h"

/* Unique tag for each SADD event */
typedef struct orsetTag {
    char node_id[CONFIG_RUN_ID_SIZE + 1]; /* source node id */
    hlc ts;                               /* event timestamp */
} orsetTag;

/* Per-member OR-Set Entry */
typedef struct orsetEntry {
    sds member;
    hashtable *tagset; /* stores (orsetTag *) tags */
} orsetEntry;

/* Per-key OR-Set */
typedef struct orset {
    sds comp_key;       /* composed key: dbid + keyname */
    hashtable *entries; /* stores (orsetEntry *) entries */
} orset;

/* OR-Set Functions */
orset *orsetCreate(sds comp_key);
void orsetFree(orset *os);
orset *orsetLookup(int dbid, sds keyname);
orsetTag *orsetAddMember(int dbid, sds key, sds member);
int orsetCollectTagsForMember(int dbid, sds key, sds member, orsetTag ***tags_out);
void orsetDelete(int dbid, sds key);
void orsetApplySadd(int dbid, sds key, sds member, const orsetTag *tag);
void orsetApplySrem(int dbid, sds key, sds member, orsetTag **tags, int ntags);

/* Hashtable Types */
extern hashtableType orsetHashtableType;
extern hashtableType orsetEntryHashtableType;
extern hashtableType orsetTagHashtableType;

#endif // ORSET_H
