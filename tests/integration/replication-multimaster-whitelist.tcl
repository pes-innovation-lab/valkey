# Multimaster command whitelist and RREPLAY metadata field.

start_server {tags {"repl external:skip"}} {
    start_server {overrides {save {}}} {
        set node0 [srv -1 client]
        set node0_host [srv -1 host]
        set node0_port [srv -1 port]
        set node1 [srv 0 client]
        set node1_host [srv 0 host]
        set node1_port [srv 0 port]

        test {Multimaster whitelist: establish active-active link} {
            $node0 config set active-replica yes
            $node0 config set multi-master yes
            $node0 config set replica-read-only no
            $node1 config set active-replica yes
            $node1 config set multi-master yes
            $node1 config set replica-read-only no

            # Database id the test client operates on, for manually crafted
            # RREPLAY frames below.
            set dbid 0
            regexp {db=([0-9]+)} [$node0 client info] _ dbid

            $node1 multimaster add $node0_host $node0_port
            wait_for_condition 100 100 {
                [s -1 active_upstream_runtime_links] >= 1 &&
                [s 0 active_upstream_runtime_links] >= 1
            } else {
                fail "Initial replica link not established"
            }
        }

        test {Non-whitelisted write is rejected and not applied locally} {
            $node0 del mm:wl:reject
            $node0 config set multi-master-whitelist "lset"
            assert_error "ERR command 'rpush' is not whitelisted in multi-master mode. The operation was not applied." {$node0 rpush mm:wl:reject a}
            # The command must not have touched the local keyspace.
            assert_equal 0 [$node0 exists mm:wl:reject]
            $node0 config set multi-master-whitelist ""
        }

        test {Whitelisted command executes locally and replicates via RREPLAY} {
            $node0 del mm:wl:list
            $node0 config set multi-master-whitelist "rpush lset"
            assert_equal 3 [$node0 rpush mm:wl:list a b c]
            assert_equal OK [$node0 lset mm:wl:list 0 X]
            assert_equal {X b c} [$node0 lrange mm:wl:list 0 -1]
            wait_for_condition 100 100 {
                [$node1 lrange mm:wl:list 0 -1] eq {X b c}
            } else {
                fail "whitelisted write did not replicate to node1"
            }
            $node0 config set multi-master-whitelist ""
        }

        test {CONFIG SET/GET multi-master-whitelist works at runtime} {
            $node0 config set multi-master-whitelist "lset set hset"
            set got [lindex [$node0 config get multi-master-whitelist] 1]
            assert_equal {hset lset set} [lsort $got]
            $node0 config set multi-master-whitelist ""
            assert_equal {} [lindex [$node0 config get multi-master-whitelist] 1]
        }

        test {CONFIG REWRITE persists the whitelist} {
            $node0 config set multi-master-whitelist "set hset"
            $node0 config rewrite
            set config_file [srv -1 config_file]
            
            # Read the config file and check for the whitelist
            set fp [open $config_file r]
            set config_content [read $fp]
            close $fp
            
            # The config file should contain the line exactly as rewritten
            assert_match {*multi-master-whitelist set hset*} $config_content
            
            # Clean up
            $node0 config set multi-master-whitelist ""
            $node0 config rewrite
        }

        test {Empty whitelist allows all commands (backward compat)} {
            $node0 config set multi-master-whitelist ""
            $node0 del mm:wl:empty
            assert_equal 3 [$node0 rpush mm:wl:empty a b c]
            assert_equal 3 [$node0 llen mm:wl:empty]
        }

        test {Multimaster metadata none round-trips through RREPLAY} {
            $node0 del mm:meta:ok
            $node0 config set multi-master-whitelist "set"
            assert_equal OK [$node0 replconf capa rreplay-peer]
            set ts [expr {[s -1 hlc_clock_wall] + 100000}]
            assert_equal 30001 [$node0 rreplay 5555555555555555555555555555555555555555 $dbid 30001 $ts-0 none set mm:meta:ok yes]
            assert_equal "yes" [$node0 get mm:meta:ok]
            $node0 config set multi-master-whitelist ""
        }

        test {Actual round-trip SET operation replicates between peers} {
            $node0 del mm:wl:set:rt
            $node1 del mm:wl:set:rt
            # Allow wait for del propagation if needed, or just rely on unique key
            
            $node0 config set multi-master-whitelist "set"
            $node1 config set multi-master-whitelist "set"
            
            # Write to node0, replicate to node1
            assert_equal OK [$node0 set mm:wl:set:rt from_node0]
            assert_equal {from_node0} [$node0 get mm:wl:set:rt]
            
            wait_for_condition 100 100 {
                [$node1 get mm:wl:set:rt] eq {from_node0}
            } else {
                fail "whitelisted SET did not replicate to node1"
            }
            
            # Write to node1, replicate to node0
            assert_equal OK [$node1 set mm:wl:set:rt from_node1]
            assert_equal {from_node1} [$node1 get mm:wl:set:rt]
            
            wait_for_condition 100 100 {
                [$node0 get mm:wl:set:rt] eq {from_node1}
            } else {
                fail "whitelisted SET did not replicate to node0"
            }
            
            $node0 config set multi-master-whitelist ""
            $node1 config set multi-master-whitelist ""
        }

        test {Bad metadata is rejected gracefully} {
            $node0 del mm:meta:bad
            $node0 config set multi-master-whitelist "set"
            assert_equal OK [$node0 replconf capa rreplay-peer]
            set ts [expr {[s -1 hlc_clock_wall] + 100000}]
            # Unrecognized metadata is skipped without tearing down the link: the
            # peer link still ACKs with the replay id, but the command is dropped.
            assert_equal 30002 [$node0 rreplay 5555555555555555555555555555555555555555 $dbid 30002 $ts-0 rga:anchor set mm:meta:bad nope]
            assert_equal 0 [$node0 exists mm:meta:bad]
            $node0 config set multi-master-whitelist ""
        }
    }
}
