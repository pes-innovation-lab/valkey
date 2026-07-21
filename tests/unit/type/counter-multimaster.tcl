# Tests for the counter handler in counter_handler.c. INCR, DECR,
# INCRBY and DECRBY converge as plain deltas, so the handler only
# needs to make getMultimasterWhitelistedHandler() return non NULL,
# which skips RMW rewrite and the HLC staleness drop for them.

start_server {tags {"string" "incr" "counter"}} {
    set dbid 0
    regexp {db=([0-9]+)} [r client info] _ dbid

    set ::counter_ts_counter 0
    proc counter_ts {} {
        incr ::counter_ts_counter
        set now [r time]
        set now_us [expr {[lindex $now 0] * 1000000 + [lindex $now 1]}]
        return [expr {$now_us + $::counter_ts_counter}]
    }

    test {counter: INCR/DECR/INCRBY/DECRBY behave normally when whitelisted} {
        r config set multi-master-whitelist "incr decr incrby decrby"
        r del ctr:basic
        r set ctr:basic 10
        assert_equal 11 [r incr ctr:basic]
        assert_equal 10 [r decr ctr:basic]
        assert_equal 15 [r incrby ctr:basic 5]
        assert_equal 10 [r decrby ctr:basic 5]
        # Unlike BWRGA, whitelisting a counter command never changes
        # the key's encoding. The value stays a plain integer throughout.
        assert_encoding int ctr:basic
        r config set multi-master-whitelist ""
    }

    test {counter: RREPLAY replays INCRBY/DECRBY frames from a remote origin} {
        set origin 5555555555555555555555555555555555555555
        r config set multi-master-whitelist "incr decr incrby decrby"
        r del ctr:replay
        r set ctr:replay 100

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [counter_ts]
        # counterSerialize() only ever emits the "none" sentinel, so a
        # counter RREPLAY frame's metadata field is always literally none.
        r rreplay $origin $dbid 9501 $ts-0 none incrby ctr:replay 5
        assert_equal 105 [r get ctr:replay]

        set ts2 [counter_ts]
        r rreplay $origin $dbid 9502 $ts2-0 none decrby ctr:replay 3
        assert_equal 102 [r get ctr:replay]
        r config set multi-master-whitelist ""
    }

    test {counter: a stale RREPLAY frame is still applied when whitelisted} {
        set origin 6666666666666666666666666666666666666666
        r config set multi-master-whitelist "incr decr incrby decrby"
        r del ctr:stale
        r set ctr:stale 0

        assert_equal OK [r replconf capa rreplay-peer]
        # Frame 1 stamps the key's HLC clock forward.
        set ts_new [counter_ts]
        r rreplay $origin $dbid 9601 $ts_new-0 none incrby ctr:stale 10
        assert_equal 10 [r get ctr:stale]

        # Frame 2's timestamp is a full second older than the key's HLC
        # clock. A plain command would be dropped here as stale (see
        # the next test). A registered handler exempts counters from
        # that drop, since the delta is commutative and must still apply.
        set ts_old [expr {$ts_new - 1000000}]
        r rreplay $origin $dbid 9602 $ts_old-0 none incrby ctr:stale 5
        assert_equal 15 [r get ctr:stale]
        r config set multi-master-whitelist ""
    }

    test {counter: without a handler, a raw INCRBY RREPLAY frame is rejected} {
        set origin 7777777777777777777777777777777777777777
        r del ctr:nowhitelist
        r set ctr:nowhitelist 0

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [counter_ts]
        # Without a handler, incrby counts as a risky read modify write
        # command. A real peer would have turned it into a SET before
        # sending it, so a raw incrby frame here is a protocol
        # violation: it gets rejected and the connection is closed.
        assert_error "*" {r rreplay $origin $dbid 9701 $ts-0 none incrby ctr:nowhitelist 10}
        reconnect
        assert_equal 0 [r get ctr:nowhitelist]
    }

    test {counter: unrecognized metadata on a whitelisted counter command is dropped} {
        set origin 8888888888888888888888888888888888888888
        r config set multi-master-whitelist "incr decr incrby decrby"
        r del ctr:badmeta
        r set ctr:badmeta 0

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [counter_ts]
        assert_equal 9801 [r rreplay $origin $dbid 9801 $ts-0 garbage-metadata incrby ctr:badmeta 5]
        assert_equal 0 [r get ctr:badmeta]
        r config set multi-master-whitelist ""
    }
}
