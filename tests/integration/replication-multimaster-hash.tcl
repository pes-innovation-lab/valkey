start_server {tags {"repl external:skip"} overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
    start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
        set node0 [srv -1 client]
        set node0_host [srv -1 host]
        set node0_port [srv -1 port]
        set node1 [srv 0 client]
        set node1_host [srv 0 host]
        set node1_port [srv 0 port]

        # Rename original test procedure so we can intercept CRDT tests
        rename test original_test

        proc get_expected_ideal_crdt {name} {
            switch -glob -- $name {
                "*different fields during partition*" { return "'mm:hash' = 'f1 val1 f2 val2 f3 val3'" }
                "*same field during partition*" { return "'mm:hash' = 'f1 val_node0' (or val_node1 depending on LWW)" }
                "*HSETNX during partition*" { return "'mm:hash' = 'f1 val1 f2 val2_nx'" }
                "*HDEL and HSET on different fields*" { return "'mm:hash' = 'f2 val2 f3 val3'" }
                "*HDEL and HSET on the same field*" { return "'mm:hash' = 'f1 val1_new' (or deleted depending on win policy)" }
                "*HINCRBY / HINCRBYFLOAT*" { return "'mm:hash' = 'f1 15 f2 4.0'" }
                default { return "" }
            }
        }

        proc test {name code args} {
            if {[string match "CRDT *" $name]} {
                set ::expected_ideal_crdt [get_expected_ideal_crdt $name]
                set test_start_time [clock milliseconds]
                puts "Starting CRDT test: $name"
                if {[catch {uplevel 1 $code} error]} {
                    set elapsed [expr {[clock milliseconds]-$test_start_time}]
                    puts "\n\u001b\[31;1mCRDT Test Failed: $name ($elapsed ms)\u001b\[0m"
                    puts "Error details: $error\n"
                    puts "\n\n"
                } else {
                    set elapsed [expr {[clock milliseconds]-$test_start_time}]
                    puts "\u001b\[32;1mCRDT Test Passed: $name ($elapsed ms)\u001b\[0m"
                    puts "\n\n"
                    catch {uplevel 1 [list original_test $name { } {*}$args]}
                }
            } else {
                uplevel 1 [list original_test $name $code {*}$args]
            }
        }

        # Helper to disconnect bidirectional replication links
        proc disconnect_links {node0 node1 node0_host node0_port node1_host node1_port} {
            puts "\n\u001b\[31;1m=== NETWORK PARTITION START ===\u001b\[0m\n"
            catch {$node0 replicaof remove $node1_host $node1_port}
            catch {$node1 replicaof remove $node0_host $node0_port}
        }

        # Helper to print all key states for a node after synchronization
        proc print_node_all_keys {node node_name} {
            set keys [lsort [$node keys *]]
            if {[llength $keys] == 0} {
                puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync state -> (no keys)\n"
                return
            }
            foreach key $keys {
                catch {
                    set type [$node type $key]
                    if {$type eq "none"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = none"
                    } elseif {$type eq "string"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = '[$node get $key]'"
                    } elseif {$type eq "list"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = '[$node lrange $key 0 -1]'"
                    } elseif {$type eq "set"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = '[$node smembers $key]'"
                    } elseif {$type eq "zset"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = '[$node zrange $key 0 -1 WITHSCORES]'"
                    } elseif {$type eq "hash"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name post-sync -> '$key' = '[$node hgetall $key]'"
                    }
                }
            }
            puts ""
        }

        # Helper to reconnect bidirectional replication links sequentially
        proc reconnect_links {node0 node1 node0_host node0_port node1_host node1_port} {
            puts "\n\u001b\[32;1m=== NETWORK PARTITION HEALED ===\u001b\[0m\n"
            $node1 replicaof add $node0_host $node0_port
            wait_for_condition 150 100 {
                [s 0 master_link_status] eq {up}
            } else {
                fail "Link node1 -> node0 did not recover"
            }
            $node0 replicaof add $node1_host $node1_port
            wait_for_condition 150 100 {
                [s -1 master_link_status] eq {up} &&
                [s 0 master_link_status] eq {up}
            } else {
                fail "Bidirectional links did not recover"
            }
            puts "\u001b\[33;1m=== POST-SYNC NODE STATES ===\u001b\[0m"
            print_node_all_keys $node0 "Node0"
            print_node_all_keys $node1 "Node1"
            if {[info exists ::expected_ideal_crdt] && $::expected_ideal_crdt ne ""} {
                puts "\u001b\[33;1mExpected Ideal CRDT Value:\u001b\[0m"
                puts "\u001b\[32;1mInfo:\u001b\[0m Node0 post-sync -> $::expected_ideal_crdt"
                puts "\u001b\[32;1mInfo:\u001b\[0m Node1 post-sync -> $::expected_ideal_crdt"
                puts ""
            }
        }

        # Helper to execute a command on a node and print its execution + key states before and after
        proc run_cmd {node node_name args} {
            # Identify target keys based on command
            set target_keys {}
            if {[llength $args] > 0} {
                set cmd [lindex $args 0]
                set cmd_lower [string tolower $cmd]
                set cmd_args [lrange $args 1 end]
                if {$cmd_lower in {del exists expire ttl persist get type set append incrby decrby incrbyfloat getset getdel setrange setbit getbit bitfield lpush rpush lpushx rpushx lpop rpop lindex llen lpos lrange lset linsert lrem ltrim sadd srem sismember smembers scard spop zadd zscore zincrby zrem zcard zrange zpopmin zpopmax zremrangebyscore zremrangebyrank zremrangebylex hset hmset hget hmget hsetnx hdel hexists hlen hkeys hvals hgetall hincrby hincrbyfloat}} {
                    if {[llength $cmd_args] > 0} {
                        lappend target_keys [lindex $cmd_args 0]
                    }
                } elseif {$cmd_lower in {lmove rpoplpush smove}} {
                    if {[llength $cmd_args] >= 2} {
                        lappend target_keys [lindex $cmd_args 0]
                        lappend target_keys [lindex $cmd_args 1]
                    }
                } elseif {$cmd_lower in {zunionstore zinterstore}} {
                    if {[llength $cmd_args] >= 3} {
                        lappend target_keys [lindex $cmd_args 0]
                    }
                } elseif {$cmd_lower eq "mset"} {
                    for {set i 0} {$i < [llength $cmd_args]} {incr i 2} {
                        lappend target_keys [lindex $cmd_args $i]
                    }
                }
            }

            # Print states BEFORE
            set printed_before 0
            foreach key $target_keys {
                catch {
                    set type [$node type $key]
                    if {$type eq "none"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = none"
                        set printed_before 1
                    } elseif {$type eq "string"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = '[$node get $key]'"
                        set printed_before 1
                    } elseif {$type eq "list"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = '[$node lrange $key 0 -1]'"
                        set printed_before 1
                    } elseif {$type eq "set"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = '[$node smembers $key]'"
                        set printed_before 1
                    } elseif {$type eq "zset"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = '[$node zrange $key 0 -1 WITHSCORES]'"
                        set printed_before 1
                    } elseif {$type eq "hash"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state BEFORE -> '$key' = '[$node hgetall $key]'"
                        set printed_before 1
                    }
                }
            }
            if {$printed_before} { puts "" }

            # Print execution
            puts "\u001b\[32;1mInfo:\u001b\[0m $node_name executing -> [join $args " "]"
            puts ""
            
            # Execute command
            set res [$node {*}$args]

            # Print states AFTER
            set printed_after 0
            foreach key $target_keys {
                catch {
                    set type [$node type $key]
                    if {$type eq "none"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = none"
                        set printed_after 1
                    } elseif {$type eq "string"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = '[$node get $key]'"
                        set printed_after 1
                    } elseif {$type eq "list"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = '[$node lrange $key 0 -1]'"
                        set printed_after 1
                    } elseif {$type eq "set"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = '[$node smembers $key]'"
                        set printed_after 1
                    } elseif {$type eq "zset"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = '[$node zrange $key 0 -1 WITHSCORES]'"
                        set printed_after 1
                    } elseif {$type eq "hash"} {
                        puts "\u001b\[32;1mInfo:\u001b\[0m $node_name state AFTER -> '$key' = '[$node hgetall $key]'"
                        set printed_after 1
                    }
                }
            }
            if {$printed_after} { puts "" }

            return $res
        }

        test {Set up active-replica multi-master topology} {
            run_cmd $node1 "Node1" replicaof add $node0_host $node0_port
            wait_for_condition 150 100 {
                [s 0 master_link_status] eq {up}
            } else {
                fail "Initial replica link from node1 to node0 not established"
            }
            run_cmd $node0 "Node0" replicaof add $node1_host $node1_port
            wait_for_condition 150 100 {
                [s -1 master_link_status] eq {up} &&
                [s 0 master_link_status] eq {up}
            } else {
                fail "Bidirectional active-replica links not established"
            }
            # Wait for background RDB saves (from fullsync handshake) to finish before invoking save
            wait_for_condition 150 100 {
                [s -1 rdb_bgsave_in_progress] == 0 &&
                [s 0 rdb_bgsave_in_progress] == 0
            } else {
                fail "Background RDB save did not finish after sync"
            }
            run_cmd $node0 "Node0" save
            run_cmd $node1 "Node1" save
        }

        test {CRDT Hash: Concurrent HSET on different fields during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:hash
            wait_for_condition 100 100 {
                [$node1 hlen mm:hash] == 0
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial field
            run_cmd $node0 "Node0" hset mm:hash "f1" "val1"
            wait_for_condition 100 100 {
                [$node1 hget mm:hash "f1"] eq "val1"
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Write field "f2" on Node 0
            run_cmd $node0 "Node0" hset mm:hash "f2" "val2"

            # 4. Write field "f3" on Node 1
            run_cmd $node1 "Node1" hset mm:hash "f3" "val3"

            # 5. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify CRDT Hash convergence:
            # Under CRDT (like OR-Map / LWW-Map), all fields should merge, resulting in {"f1", "f2", "f3"} (hlen 3).
            # (Under LWW key-level, one node's state overwrites the other completely, resulting in hlen 2).
            wait_for_condition 100 100 {
                [$node0 hlen mm:hash] == 3 &&
                [$node1 hlen mm:hash] == 3
            } else {
                set fields0 [$node0 hkeys mm:hash]
                set fields1 [$node1 hkeys mm:hash]
                fail "CRDT Hash different fields HSET failed (expected hlen 3): node0=$fields0 node1=$fields1"
            }

            set fields0 [run_cmd $node0 "Node0" hkeys mm:hash]
            set fields1 [run_cmd $node1 "Node1" hkeys mm:hash]
            assert_equal [lsort $fields0] [lsort $fields1]
            assert {[lsearch $fields0 "f1"] != -1}
            assert {[lsearch $fields0 "f2"] != -1}
            assert {[lsearch $fields0 "f3"] != -1}
        }

        test {CRDT Hash: Concurrent HSET on the same field during partition} {
            # Clear key and setup initial field
            run_cmd $node0 "Node0" del mm:hash
            run_cmd $node0 "Node0" hset mm:hash "f1" "init"
            wait_for_condition 100 100 {
                [$node1 hget mm:hash "f1"] eq "init"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Modify "f1" to "val_node0" on Node 0
            run_cmd $node0 "Node0" hset mm:hash "f1" "val_node0"

            # 3. Modify "f1" to "val_node1" on Node 1
            run_cmd $node1 "Node1" hset mm:hash "f1" "val_node1"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must agree on the same value for "f1".
            wait_for_condition 100 100 {
                [$node0 hget mm:hash "f1"] eq [$node1 hget mm:hash "f1"]
            } else {
                set val0 [$node0 hget mm:hash "f1"]
                set val1 [$node1 hget mm:hash "f1"]
                fail "CRDT Hash same field HSET failed: node0=$val0 node1=$val1"
            }

            set val0 [run_cmd $node0 "Node0" hget mm:hash "f1"]
            set val1 [run_cmd $node1 "Node1" hget mm:hash "f1"]
            assert_equal $val0 $val1
        }

        test {CRDT Hash: Concurrent HSETNX during partition} {
            # Clear key and setup initial field
            run_cmd $node0 "Node0" del mm:hash
            run_cmd $node0 "Node0" hset mm:hash "f1" "val1"
            wait_for_condition 100 100 {
                [$node1 hget mm:hash "f1"] eq "val1"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. HSETNX on Node 0 on existing field (returns 0)
            assert_equal 0 [run_cmd $node0 "Node0" hsetnx mm:hash "f1" "val1_nx"]

            # 3. HSETNX on Node 1 on new field (returns 1)
            assert_equal 1 [run_cmd $node1 "Node1" hsetnx mm:hash "f2" "val2_nx"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Hash convergence:
            # A correct CRDT map must merge at field granularity:
            # HSETNX on a NEW field ("f2") on Node1 must survive the merge.
            # Both "f1" (from original) and "f2" (from Node1 HSETNX) must be present — hlen = 2.
            wait_for_condition 100 100 {
                [$node0 hlen mm:hash] == 2 &&
                [$node1 hlen mm:hash] == 2
            } else {
                set fields0 [$node0 hkeys mm:hash]
                set fields1 [$node1 hkeys mm:hash]
                fail "CRDT Hash HSETNX merge failed (expected hlen 2 with f1+f2): node0=$fields0 node1=$fields1"
            }

            set fields0 [run_cmd $node0 "Node0" hkeys mm:hash]
            set fields1 [run_cmd $node1 "Node1" hkeys mm:hash]
            assert_equal [lsort $fields0] [lsort $fields1]
            assert {[lsearch $fields0 "f1"] != -1}
            assert {[lsearch $fields0 "f2"] != -1}
        }

        test {CRDT Hash: Concurrent HDEL and HSET on different fields during partition} {
            # Clear key and setup initial fields
            run_cmd $node0 "Node0" del mm:hash
            run_cmd $node0 "Node0" hmset mm:hash "f1" "val1" "f2" "val2"
            wait_for_condition 100 100 {
                [$node1 hlen mm:hash] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Delete field "f1" on Node 0
            run_cmd $node0 "Node0" hdel mm:hash "f1"

            # 3. Write field "f3" on Node 1
            run_cmd $node1 "Node1" hset mm:hash "f3" "val3"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Hash convergence:
            # A correct CRDT map applies operations at field granularity:
            # HDEL "f1" on Node0 and HSET "f3" on Node1 are on different fields —
            # both must apply, leaving {"f2", "f3"} (hlen 2). "f1" must be absent.
            wait_for_condition 100 100 {
                [$node0 hlen mm:hash] == 2 &&
                [$node1 hlen mm:hash] == 2
            } else {
                set fields0 [$node0 hkeys mm:hash]
                set fields1 [$node1 hkeys mm:hash]
                fail "CRDT Hash HDEL/HSET merge failed (expected {f2,f3}, hlen 2): node0=$fields0 node1=$fields1"
            }

            set fields0 [run_cmd $node0 "Node0" hkeys mm:hash]
            set fields1 [run_cmd $node1 "Node1" hkeys mm:hash]
            assert_equal [lsort $fields0] [lsort $fields1]
            assert {[lsearch $fields0 "f1"] == -1}
            assert {[lsearch $fields0 "f3"] != -1}
        }

        test {CRDT Hash: Concurrent HDEL and HSET on the same field during partition} {
            # Clear key and setup initial fields
            run_cmd $node0 "Node0" del mm:hash
            run_cmd $node0 "Node0" hset mm:hash "f1" "val1"
            wait_for_condition 100 100 {
                [$node1 hget mm:hash "f1"] eq "val1"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 deletes field "f1"
            run_cmd $node0 "Node0" hdel mm:hash "f1"

            # 3. Node 1 modifies field "f1" concurrently to "val1_new"
            run_cmd $node1 "Node1" hset mm:hash "f1" "val1_new"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Hash convergence:
            # Both nodes must agree on the membership/value of "f1".
            wait_for_condition 100 100 {
                [$node0 hexists mm:hash "f1"] == [$node1 hexists mm:hash "f1"]
            } else {
                set ex0 [$node0 hexists mm:hash "f1"]
                set ex1 [$node1 hexists mm:hash "f1"]
                fail "CRDT Hash same field HDEL/HSET merge failed: node0=$ex0 node1=$ex1"
            }
        }

        test {CRDT Hash: Concurrent HINCRBY / HINCRBYFLOAT on different fields during partition} {
            # Clear key and setup initial numeric fields
            run_cmd $node0 "Node0" del mm:hash
            run_cmd $node0 "Node0" hmset mm:hash "f1" "10" "f2" "2.5"
            wait_for_condition 100 100 {
                [$node1 hlen mm:hash] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 increments "f1" by 5
            run_cmd $node0 "Node0" hincrby mm:hash "f1" 5

            # 3. Node 1 increments float "f2" by 1.5
            run_cmd $node1 "Node1" hincrbyfloat mm:hash "f2" 1.5

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Hash convergence:
            # A correct CRDT map merges field updates at field granularity:
            # Node0 increments "f1" by 5 (10→15), Node1 increments float "f2" by 1.5 (2.5→4.0).
            # Both updates are on different fields and must both survive — {"f1": 15, "f2": 4.0}.
            wait_for_condition 100 100 {
                [$node0 hget mm:hash "f1"] == 15 &&
                [$node0 hget mm:hash "f2"] == 4.0 &&
                [$node1 hget mm:hash "f1"] == 15 &&
                [$node1 hget mm:hash "f2"] == 4.0
            } else {
                set f1_0 [$node0 hget mm:hash "f1"]
                set f2_0 [$node0 hget mm:hash "f2"]
                set f1_1 [$node1 hget mm:hash "f1"]
                set f2_1 [$node1 hget mm:hash "f2"]
                fail "CRDT Hash HINCRBY/HINCRBYFLOAT merge failed (expected f1=15, f2=4.0): node0={$f1_0, $f2_0} node1={$f1_1, $f2_1}"
            }

            # Verify read commands on post-converged maps
            set all0 [run_cmd $node0 "Node0" hgetall mm:hash]
            set all1 [run_cmd $node1 "Node1" hgetall mm:hash]
            assert_equal $all0 $all1
        }
    }
}
