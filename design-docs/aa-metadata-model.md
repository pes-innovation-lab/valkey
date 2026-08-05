# Active-Active Data Model

## Problem statement

A CRDT-based active-active datastore needs every key to carry conflict-resolution metadata. For example, for last-writer-wins it is a sequence number/epoch per key that determines which is the latest write.

Two decisions follow from this - 

1. **Where do the metadata bytes live?** Inside a module-defined value, inside the engine's native structures, or somewhere alongside them.
2. **Where does the conflict resolution logic run?** In a module that reimplements each command, or inside the engine's existing command handlers.

The first decides how much memory the metadata costs and who is allowed to define its meaning. The second decides how much of the engine's command implementation we have to duplicate. 

This document attempts to initiate discussion for both of the problems.

---

## Goals

**Modularity — the ability to support different kinds of CRDT.** One of the thing we have aligned on to provision the ability to define different CRDT implementation for a data type. For example, a CRDT requiring tombstone might need different metadata compared to LWW based CRDT. 

**Minimal memory overhead when active-active is not in use.** Active-active is a minority configuration; so additional allocation when AA is disabled should be avoided.

**Reuse of the native command handlers.** The engine's command implementations carry a large amount of argument handling and edge-case semantics — `SET` with `NX`/`XX`/`GET`/`EX`/`IFEQ`, hash field expiration, automatic encoding conversion, reply object creation. We should attempt to re-use pre-existing functionality with minimal code changes in Valkey engine.

---

## Proposal

Active-active needs exactly two additions to the engine: **a place to put opaque metadata bytes**, and **hooks to execute CRDT resolution**. Everything else, the conflict resolution policy, the meaning of the metadata, and any richer CRDT state lives in the module and is invisible to the engine.

### 1. Metadata reservation

At load time a module declares how many bytes it needs per key, and per collection element. The engine adds that to the relevant allocations. The bytes are opaque: the engine allocates, moves, and frees them, but never interprets them.

```c
/* Called during module load, before any keys exist. */
int VM_ReserveObjectMetadata(ValkeyModuleCtx *ctx, size_t size);
int VM_ReserveElementMetadata(ValkeyModuleCtx *ctx, size_t size);

/* Returns a writable pointer into the reserved region, or NULL. */
void *VM_GetObjectMetadata(ValkeyModuleKey *key);
```

Based on these reservation API calls, engine can know how many bytes to allocate when a key or a collection item is created.

If we want to generalize the need to metadata reservevation for all kinds of module then, a handle-based registry is needed, so that more than one module can reserve independently and the engine can figure out the ownership.

#### Key-level layout

The reserved region sits in the object's trailing data, after the embedded key:

```
+----------+---------+--------+---------+----------+
| robj hdr | val_ptr | expire | key sds | AA meta  |
| (16B)    | (8B)    | (8B)   |         | N bytes  |
+----------+---------+--------+---------+----------+
```

The reservation is unconditional rather than flagged per key because every active-active key needs a sequence number. This metadata allocation should only happen during key creation or reallocation.

#### Item-level layout

The same idea extends to collection elements i.e the reserved bytes are prepended and reached by subtracting a known offset.

Hash — the entry structure

```
+------------------+----------+------------+---------+-----------+
| module metadata  | expire?  | value_ptr? | sdshdr8 | field buf |
| (N bytes)        | (opt 8B) | (opt 8B)   |         |           |
+------------------+----------+------------+---------+-----------+
^                                          ^
|                                          entry pointer (sds)
VM_HashFieldGetMetadata() returns this
```

Set — entry structure

```
+------------------+--------+-------+-------+------+----+
| module metadata  | len(1) | alloc | flags | data | \0 |
| (N bytes)        |        |       |       |      |    |
+------------------+--------+-------+-------+------+----+
^                                   ^
|                                   sds pointer (in bucket)
VM_SetMemberGetMetadata() returns this
```

Sorted set — ZskipListNode. In this case, metadata is reserved as trailing bytes.

```
+-------+----------+----------+-----+------------------+---+--------+------+
| score | backward | level[0] | ... | module metadata  | 1 | sdshdr | elem |
|       |          |          |     | (N bytes)        |   |        |      |
+-------+----------+----------+-----+------------------+---+--------+------+
                                     ^
                                     VM_ZsetMemberGetMetadata() returns this
```

```c
void *VM_HashFieldGetMetadata(ValkeyModuleKey *key, ValkeyModuleString *field);
void *VM_SetMemberGetMetadata(ValkeyModuleKey *key, ValkeyModuleString *member);
void *VM_ZsetMemberGetMetadata(ValkeyModuleKey *key, ValkeyModuleString *member);
```

If a module's metadata needs to own heap memory — a tombstone list, for example — it stores a pointer in the reserved region and registers a free callback so the engine can invoke it when the element or key is destroyed.

It is difficult to incorporate encodings like listpack and intset into this scheme which will bring memory regression on small collections and this can be tackled in future.

### 2. Pre-write and post-write hooks

The conflict resolution decision runs inside the native command handler via module callbacks. A module registers callbacks per type; the handler calls out at two points and is otherwise unchanged.

- **Pre-write hook** — runs before the mutation and returns a verdict: accept, reject, or accept-and-replace based on the conflict resolution logic inside the module callback.
- **Post-write hook** — runs after the mutation and handles replication: stamping the key-level sequence number, forming AA transaction carrying required metadata, etc.

```c
int ModuleInit(ValkeyModuleCtx *ctx) {
    VM_AA_RegisterHook(ctx, OBJ_STRING, crdt_string_prewrite, crdt_string_postwrite);
    VM_AA_RegisterHook(ctx, OBJ_HASH,   crdt_hash_prewrite,   crdt_hash_postwrite);
}

// lives inside module
int crdt_string_prewrite(CRDTPreWriteCtx *ctx) {
    uint64_t existing = crdt_get_key_seqno(ctx->key);

    if (ctx->existing_value->type == OBJ_STRING) {
        /* Same type: plain last-writer-wins. */
        return (existing > ctx->incoming_seqno) ? CRDT_REJECT : CRDT_ACCEPT;
    }

    /* Different type: create-create conflict. */
    return (ctx->incoming_seqno > existing) ? CRDT_ACCEPT_REPLACE : CRDT_REJECT;
}
```

For `SET`, which has a single lookup followed by a single write, this is one pre-write call per command:

```
                    SET key value [NX|XX|GET|EX...]
                         setGenericCommand()
                                 |
                                 v
                   Parse and general validation
                                 |
              +==================v====================+
              |  verdict = crdt_prewrite(ctx)         |  <-- registered callback
              +======+============+==============+====+
                     |            |              |
              REJECT |     ACCEPT |ACCEPT_REPLACE|
                     v            |              v
            +----------------+    |    +------------------------+
            |  reply, return |    |    | dbDelete(key)          |
            |  (no mutation) |    |    | mark replaced for post |
            +----------------+    |    +-----------+------------+
                                  +---------+------+
                                            |
                                            v
                        +---------------------------------------+
                        |  NATIVE WRITE                         |
                        |  setKey(); dirty++; notify("set")     |
                        +-------------------+-------------------+
              +=============================v=========================+
              |  crdt_postwrite(ctx)                                  |  <-- registered callback
              |    stamp key seqno; build transaction to replicate,etc|
              +=======================================================+
```

Collection commands need the pre-write hook **per item**, because the decision is per item while the propagation is per command. `HSET key f1 v1 f2 v2 f3 v3` is three independent comparisons, and the engine visits one field at a time; a rejected field is skipped and the loop continues. Replication happens once, carrying only the fields that won. So collections take N pre-write calls and one post-write call.

---

## Other approaches considered

### Where the metadata lives

#### Module-owned type

The module owns both the value and the metadata. The key is stored as a module-defined type rather than a native one, and that struct holds the value alongside its CRDT state.

```
robj {
    type = OBJ_MODULE
    val_ptr -> moduleValue {
        .type  -> CRDT_STRING_TYPE   (vtable: rdb_load / rdb_save / free)
        .value -> CRDTString {
            string_type: Sds("value")   <- the actual data
            seq_no:      SeqNo(...)     <- LWW epoch
        }
    }
}
```

This gives the most freedom to structure the metadata and the strongest isolation from the engine, and it requires no engine change at all.

The costs with this is that — every command's argument handling is reimplemented in the module, and it drifts from native semantics as the engine and becomes painful to support new changes in the engine.

#### Native CRDT support

Give metadata ownership to the engine: a key-level sequence number as a native field, plus per-member sequence numbers via new encodings for the collection types.

For key level, the sequence number can live as trailing bytes.
```c

struct serverObject {
    unsigned type : 4;
    unsigned encoding : 4;
    .
    .
  + unsigned hascrdt : 1; // if set, 8-byte seqno in trailing data

    void *val_ptr; 
};


// Accessors
uint64_t objectGetCrdtSeqNo(const robj *o);
void objectSetCrdtSeqNo(robj *o, uint64_t seqno); // takes care of storing seq_no as trailing data
```

Collection types can have a new encodings.

```c
#define OBJ_ENCODING_CRDT_HASHTABLE 12

typedef struct crdtHashEntry {
    sds      field;
    sds      value;
    uint64_t seqno;
} crdtHashEntry;
```

This uses the least memory of the three, since the metadata is inline with no indirection and no duplicated keys.

It fails the first goal (Modularity). Fixing the width of the sequence number in a core structure decides the conflict resolution strategy for the whole engine: eight bytes is last-writer-wins and nothing else fits. For example, a PN counter needs room per region, an add-wins set needs tombstones, and neither can be expressed in a modular way. The metadata format ends up in the engine, which is exactly what modularity requires it not to be.

**On the `has_crdt` bit.** Bits in in the RObj header are shared resource, and spending one permanently on a minority feature taxes every other usecase that never enable active-active. Reservation achieves the same layout without claiming a bit.

 #### Metadata side store in the engine

 Leave every value exactly as it is today and keep the metadata in a separate table owned by the engine, one entry per key and, for collections, one entry per item. A write looks the value up in the main keyspace and looks its metadata up in the side table.
 
 ```
         main keyspace                          metadata side store
    +---------------------+              +--------------------------------+
    | "user:1"  -> robj   |  ----------> | "user:1"         -> seq_no     |
    | "h"       -> robj   |  ----------> | "h"              -> seq_no     |
    +---------------------+              | ("h", "field1")  -> seq_no     |
                                         | ("h", "field2")  -> seq_no     |
                                         +--------------------------------+
               unchanged                    keyed by name, not by pointer
 ```
 
 The attraction is that it needs no layout change anywhere. Values keep their existing allocations, listpack and intset survive, the metadata can be any size or shape the module wants, and there is no per-type work — one table serves strings, hashes, sets, and sorted sets alike.

 The problem is that the side store is a second copy of the keys (troublesome for large keys), and it has to be maintained whenever the engine moves, duplicates, renames, or destroys a key or an item. For example, slot migration and rdb will need serialization from this side store as well, key deletion require deleting the entry from the side store, etc.
 
 Overall, every keyspace mutation path must now maintain, and getting one of those paths wrong produces a silent leak or a silently wrong resolution.

### Where the conflict resolution runs

#### Full command interception in the module

The module registers a handler for each write command, opens the key as its own type, and inlines the resolution logic. This gives complete isolation and needs no engine change.

This requires all of the engine's argument handling is duplicated. `SET` alone means re-parsing `NX`, `XX`, `GET`, `EX`, `PX`, `EXAT`, `KEEPTTL`, and `IFEQ`; `HSET` means reimplementing conversion, field expiry, volatile-field tracking, and the reply-shape difference from `HMSET`. Every one of those is a place the module can diverge from native behaviour, silently, as the engine changes.

The hook approach avoids the duplication at the cost of finding the right call sites in each handler. That is not uniformly easy — commands differ in shape, and some may not fit an accept / reject / replace verdict cleanly — but the sites are found once and the semantics stay in one place.

In scenario where pre-write and post-write hooks are not possible or too complex, this can be used as fallback mechanism.
