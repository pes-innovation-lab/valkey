# Tests for the BwRGA string CRDT encoding: command behavior and the
# RREPLAY replay path, using frames built by hand on one connection.
# REPLCONF capa rreplay-peer is enough to be a peer link, so no
# second server is needed. See tests/unit/rreplay.tcl for the pattern.

start_server {tags {"string" "bwrga"}} {
    # Database id this connection uses, for the dbid argument of the
    # RREPLAY frames built by hand below.
    set dbid 0
    regexp {db=([0-9]+)} [r client info] _ dbid

    # Uses real physical time, not the server's own HLC wall clock, plus
    # a small rising safety margin. Anchoring off the server's clock
    # would compound across tests, since each accepted frame can move it
    # forward, and could trip hlc-max-clock-drift and get dropped.
    set ::bwrga_ts_counter 0
    proc bwrga_ts {} {
        incr ::bwrga_ts_counter
        set now [r time]
        set now_us [expr {[lindex $now 0] * 1000000 + [lindex $now 1]}]
        return [expr {$now_us + $::bwrga_ts_counter}]
    }

    test {BWRGA: SET on a fresh key uses bwrga encoding} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:fresh
        r set bw:fresh hello
        assert_encoding bwrga bw:fresh
        assert_equal {hello} [r get bw:fresh]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SET whole-key replace on single-identity content} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:replace
        r set bw:replace hello
        r set bw:replace "by joe"
        assert_encoding bwrga bw:replace
        assert_equal {by joe} [r get bw:replace]
        assert_equal 6 [r strlen bw:replace]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: APPEND builds up content across multiple fragments} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:append
        r set bw:append "he"
        assert_equal 4 [r append bw:append "XY"]
        assert_equal 5 [r append bw:append "o"]
        assert_encoding bwrga bw:append
        assert_equal {heXYo} [r get bw:append]
        assert_equal 5 [r strlen bw:append]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SETRANGE within bounds overwrites in place} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:setrange
        r set bw:setrange "Hello World"
        assert_equal 11 [r setrange bw:setrange 6 "Redis"]
        assert_encoding bwrga bw:setrange
        assert_equal {Hello Redis} [r get bw:setrange]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: GETRANGE reads back correctly, including negative indices} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:getrange
        r set bw:getrange "Hello Redis"
        assert_equal {Hello} [r getrange bw:getrange 0 4]
        assert_equal {Redis} [r getrange bw:getrange -5 -1]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SETRANGE past the current end is rejected and leaves value untouched} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:setrange:past
        r set bw:setrange:past "Hello World"
        assert_error "*SETRANGE past the end of a BWRGA value is not yet supported*" {
            r setrange bw:setrange:past 100 "pad"
        }
        assert_equal {Hello World} [r get bw:setrange:past]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SETRANGE with a negative offset is rejected} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:setrange:neg
        r set bw:setrange:neg "Hello"
        assert_error "*offset is out of range*" {
            r setrange bw:setrange:neg -1 "x"
        }
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SET with options is rejected and leaves the key untouched} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:set:opts
        assert_error "*SET with options on a BWRGA value is not yet supported*" {
            r set bw:set:opts hello EX 100
        }
        assert_equal 0 [r exists bw:set:opts]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: SET on a multi-identity document is rejected and leaves it untouched} {
        r config set multi-master-whitelist "append setrange set"
        r del bw:set:multi
        r set bw:set:multi "he"
        r append bw:set:multi "XY"
        assert_encoding bwrga bw:set:multi
        assert_error "*SET on a BWRGA value with multiple distinct live fragments is not yet supported*" {
            r set bw:set:multi nope
        }
        assert_equal {heXY} [r get bw:set:multi]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: RREPLAY replays an APPEND frame from a remote origin} {
        set origin 1111111111111111111111111111111111111111
        r config set multi-master-whitelist "append setrange set"
        r del bw:replay:append

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [bwrga_ts]
        # Frame 1: insert "he" as one block under a known identity (id=100).
        r rreplay $origin $dbid 9101 $ts-0 "id=100:0:$origin;pred=0:0:-:0" set bw:replay:append "he"
        assert_equal {he} [r get bw:replay:append]

        set ts2 [bwrga_ts]
        # Frame 2: append "XY". Predecessor is block 100's own last
        # character 'e', at its internal offset 1, not one past it.
        r rreplay $origin $dbid 9102 $ts2-0 "id=200:0:$origin;pred=100:0:$origin:1" append bw:replay:append "XY"
        assert_equal {heXY} [r get bw:replay:append]

        set ts3 [bwrga_ts]
        # Frame 3: append "o". Predecessor is block 200's own last
        # character 'Y', at its internal offset 1.
        r rreplay $origin $dbid 9103 $ts3-0 "id=300:0:$origin;pred=200:0:$origin:1" append bw:replay:append "o"
        assert_equal {heXYo} [r get bw:replay:append]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: RREPLAY replays a SETRANGE frame with a delete range} {
        set origin 2222222222222222222222222222222222222222
        r config set multi-master-whitelist "append setrange set"
        r del bw:replay:setrange

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [bwrga_ts]
        # Frame 1: insert "Hello World" as one block under a known identity
        # (id=100), so frame 2 below can reference it directly instead of
        # guessing what identity a local SET would have picked.
        r rreplay $origin $dbid 9201 $ts-0 "id=100:0:$origin;pred=0:0:-:0" set bw:replay:setrange "Hello World"
        assert_equal {Hello World} [r get bw:replay:setrange]

        set ts2 [bwrga_ts]
        # Frame 2: overwrite offset 6..11 ("World") with "Redis". This
        # deletes block 100's offset 6..11 and inserts new block 200
        # right after offset 5 of block 100, which is the space.
        r rreplay $origin $dbid 9202 $ts2-0 "id=200:0:$origin;pred=100:0:$origin:5;delid=100:0:$origin;deloff=6;dellen=5" setrange bw:replay:setrange 6 "Redis"
        assert_equal {Hello Redis} [r get bw:replay:setrange]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: RREPLAY replays a SET frame, inserting then whole-key replacing} {
        set origin 3333333333333333333333333333333333333333
        r config set multi-master-whitelist "append setrange set"
        r del bw:replay:set

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [bwrga_ts]
        r rreplay $origin $dbid 9301 $ts-0 "id=100:0:$origin;pred=0:0:-:0" set bw:replay:set hello
        assert_equal {hello} [r get bw:replay:set]
        assert_encoding bwrga bw:replay:set

        set ts2 [bwrga_ts]
        r rreplay $origin $dbid 9302 $ts2-0 "id=200:0:$origin;pred=0:0:-:0;delid=100:0:$origin;deloff=0;dellen=5" set bw:replay:set "by joe"
        assert_equal {by joe} [r get bw:replay:set]

        # A further local SET must succeed cleanly. This proves the
        # replayed document converged to a single live identity, with
        # no leftover fragments from the replace.
        r set bw:replay:set final
        assert_equal {final} [r get bw:replay:set]
        r config set multi-master-whitelist ""
    }

    test {BWRGA: RREPLAY with unrecognized metadata is dropped without applying the write} {
        set origin 4444444444444444444444444444444444444444
        r config set multi-master-whitelist "append setrange set"
        r del bw:replay:badmeta

        assert_equal OK [r replconf capa rreplay-peer]
        set ts [bwrga_ts]
        assert_equal 9401 [r rreplay $origin $dbid 9401 $ts-0 garbage-metadata set bw:replay:badmeta nope]
        assert_equal 0 [r exists bw:replay:badmeta]
        r config set multi-master-whitelist ""
    }
}
