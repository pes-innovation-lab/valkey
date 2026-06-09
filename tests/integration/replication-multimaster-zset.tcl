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
                "*ZADD of different members*" { return "'mm:zset' = 'm1 10 m2 20 m3 30'" }
                "*ZADD of the same member with different scores*" { return "'mm:zset' = 'm1 15' (or 25 depending on win policy)" }
                "*ZINCRBY on different members*" { return "'mm:zset' = 'm1 15 m2 23'" }
                "*ZINCRBY on the same member*" { return "'mm:zset' = 'm1 18'" }
                "*ZREM and ZADD on different members*" { return "'mm:zset' = 'm2 20 m3 30'" }
                "*ZPOPMIN and ZPOPMAX*" { return "'mm:zset' = 'm2 20'" }
                "*ZREMRANGEBYSCORE*" { return "'mm:zset' = 'm2 20 m3 30'" }
                "*lexicographical range removals (ZREMRANGEBYLEX)*" { return "'mm:zset' = (empty)" }
                "*ZUNIONSTORE and ZINTERSTORE*" { return "'dst_union' and 'dst_inter' converged to identical scores for 'm1'" }
                "*Conditional ZADD options GT and LT*" { return "'mm:zset' = 'm1 15' (or 8/10 depending on condition resolution)" }
                "*ZREMRANGEBYRANK with score changes*" { return "'mm:zset' converged to identical sorted set state" }
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

        test {CRDT Zset: Concurrent ZADD of different members during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:zset
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 0
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial member
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1"
            wait_for_condition 100 100 {
                [$node1 zscore mm:zset "m1"] == 10
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Add member "m2" with score 20 on Node 0
            run_cmd $node0 "Node0" zadd mm:zset 20 "m2"

            # 4. Add member "m3" with score 30 on Node 1
            run_cmd $node1 "Node1" zadd mm:zset 30 "m3"

            # 5. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify CRDT Zset convergence:
            # Under CRDT, all members should merge, resulting in {"m1": 10, "m2": 20, "m3": 30} (zcard 3).
            # (Under LWW key-level, Node 1's write is overwritten by Node 0's sync, resulting in zcard 2).
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == 3 &&
                [$node1 zcard mm:zset] == 3
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset different members ZADD failed (expected zcard 3): node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
            assert_equal 10 [run_cmd $node0 "Node0" zscore mm:zset "m1"]
            assert_equal 20 [run_cmd $node0 "Node0" zscore mm:zset "m2"]
            assert_equal 30 [run_cmd $node0 "Node0" zscore mm:zset "m3"]
        }

        test {CRDT Zset: Concurrent ZADD of the same member with different scores during partition} {
            # Clear key and setup initial member
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1"
            wait_for_condition 100 100 {
                [$node1 zscore mm:zset "m1"] == 10
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Update score to 15 on Node 0
            run_cmd $node0 "Node0" zadd mm:zset 15 "m1"

            # 3. Update score to 25 on Node 1
            run_cmd $node1 "Node1" zadd mm:zset 25 "m1"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must agree on the same score for "m1".
            wait_for_condition 100 100 {
                [$node0 zscore mm:zset "m1"] == [$node1 zscore mm:zset "m1"]
            } else {
                set val0 [$node0 zscore mm:zset "m1"]
                set val1 [$node1 zscore mm:zset "m1"]
                fail "CRDT Zset same member ZADD failed: node0=$val0 node1=$val1"
            }

            set val0 [run_cmd $node0 "Node0" zscore mm:zset "m1"]
            set val1 [run_cmd $node1 "Node1" zscore mm:zset "m1"]
            assert_equal $val0 $val1
        }

        test {CRDT Zset: Concurrent ZINCRBY on different members during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1" 20 "m2"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Increment "m1" by 5 on Node 0
            run_cmd $node0 "Node0" zincrby mm:zset 5 "m1"

            # 3. Increment "m2" by 3 on Node 1
            run_cmd $node1 "Node1" zincrby mm:zset 3 "m2"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # Under CRDT, both score updates should merge, yielding {"m1": 15, "m2": 23}.
            # (Under LWW key-level, Node 1's write is overwritten by Node 0's sync, so "m2" remains 20).
            wait_for_condition 100 100 {
                [$node0 zscore mm:zset "m1"] == 15 &&
                [$node0 zscore mm:zset "m2"] == 23 &&
                [$node1 zscore mm:zset "m1"] == 15 &&
                [$node1 zscore mm:zset "m2"] == 23
            } else {
                set m1_0 [$node0 zscore mm:zset "m1"]
                set m2_0 [$node0 zscore mm:zset "m2"]
                set m1_1 [$node1 zscore mm:zset "m1"]
                set m2_1 [$node1 zscore mm:zset "m2"]
                fail "CRDT Zset ZINCRBY failed: node0={$m1_0, $m2_0} node1={$m1_1, $m2_1}"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
        }

        test {CRDT Zset: Concurrent ZINCRBY on the same member during partition} {
            # Clear key and setup initial member
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1"
            wait_for_condition 100 100 {
                [$node1 zscore mm:zset "m1"] == 10
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Increment "m1" by 5 on Node 0
            run_cmd $node0 "Node0" zincrby mm:zset 5 "m1"

            # 3. Increment "m1" by 3 on Node 1
            run_cmd $node1 "Node1" zincrby mm:zset 3 "m1"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # If scores act as counters, increments accumulate: 10 + 5 + 3 = 18.
            # (Under LWW, it resolves to either 15 or 13).
            wait_for_condition 100 100 {
                [$node0 zscore mm:zset "m1"] == 18 &&
                [$node1 zscore mm:zset "m1"] == 18
            } else {
                set val0 [$node0 zscore mm:zset "m1"]
                set val1 [$node1 zscore mm:zset "m1"]
                fail "CRDT Zset same member ZINCRBY failed: node0=$val0 node1=$val1"
            }
        }

        test {CRDT Zset: Concurrent ZREM and ZADD on different members during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1" 20 "m2"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Remove member "m1" on Node 0
            run_cmd $node0 "Node0" zrem mm:zset "m1"

            # 3. Add member "m3" with score 30 on Node 1
            run_cmd $node1 "Node1" zadd mm:zset 30 "m3"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # A correct CRDT must apply both operations independently:
            # Node0's ZREM deletes "m1", Node1's ZADD adds "m3" with score 30.
            # After merge: {"m2": 20, "m3": 30} (zcard 2), "m1" is absent.
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == 2 &&
                [$node1 zcard mm:zset] == 2
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset ZREM/ZADD merge failed (expected {m2:20 m3:30}): node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
            # "m1" must be gone; zscore returns empty string for missing members
            assert {[$node0 zscore mm:zset "m1"] eq {}}
            assert_equal 30 [run_cmd $node0 "Node0" zscore mm:zset "m3"]
        }

        test {CRDT Zset: Concurrent ZPOPMIN and ZPOPMAX during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1" 20 "m2" 30 "m3"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 3
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Pop minimum score member on Node 0 (removes "m1")
            assert_equal {m1 10} [run_cmd $node0 "Node0" zpopmin mm:zset 1]

            # 3. Pop maximum score member on Node 1 (removes "m3")
            assert_equal {m3 30} [run_cmd $node1 "Node1" zpopmax mm:zset 1]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # A correct CRDT must propagate both concurrent pops independently.
            # ZPOPMIN removes "m1" on Node0, ZPOPMAX removes "m3" on Node1 —
            # after merge both deletions must survive, leaving only {"m2": 20}.
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == 1 &&
                [$node1 zcard mm:zset] == 1
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset POP merge failed (expected zcard 1, only m2:20): node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
            assert_equal 20 [run_cmd $node0 "Node0" zscore mm:zset "m2"]
        }

        test {CRDT Zset: Concurrent ZREMRANGEBYSCORE during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1" 20 "m2" 30 "m3" 40 "m4"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 4
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 removes score range 0 to 15 (removes "m1")
            assert_equal 1 [run_cmd $node0 "Node0" zremrangebyscore mm:zset 0 15]

            # 3. Node 1 removes score range 35 to 50 (removes "m4")
            assert_equal 1 [run_cmd $node1 "Node1" zremrangebyscore mm:zset 35 50]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # A correct CRDT must propagate both score-range removals independently:
            # Node0 removes "m1" (0–15), Node1 removes "m4" (35–50).
            # Both deletions must survive — leaving {"m2": 20, "m3": 30} (zcard 2).
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == 2 &&
                [$node1 zcard mm:zset] == 2
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset ZREMRANGEBYSCORE merge failed (expected {m2:20 m3:30}): node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
            assert_equal {m2 20 m3 30} $range0
        }

        test {CRDT Zset: Concurrent lexicographical range removals (ZREMRANGEBYLEX) during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 0 "a" 0 "b" 0 "c" 0 "d"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 4
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 removes lexicographical range "a" to "b" (removes "a" and "b")
            assert_equal 2 [run_cmd $node0 "Node0" zremrangebylex mm:zset \[a \[b]

            # 3. Node 1 removes lexicographical range "c" to "d" (removes "c" and "d")
            assert_equal 2 [run_cmd $node1 "Node1" zremrangebylex mm:zset \[c \[d]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Zset convergence:
            # A correct CRDT must propagate both lex-range removals independently:
            # Node0 removes {a, b}, Node1 removes {c, d} — together all 4 elements
            # are deleted. Both deletions must survive, leaving an empty set (zcard 0).
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == 0 &&
                [$node1 zcard mm:zset] == 0
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset ZREMRANGEBYLEX merge failed (expected empty set): node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
            assert_equal {} $range0
        }

        test {CRDT Zset: ZUNIONSTORE and ZINTERSTORE aggregate options concurrency during partition} {
            # Clear keys
            run_cmd $node0 "Node0" del src1 src2 dst_union dst_inter
            wait_for_condition 100 100 {
                [$node1 exists src1] == 0 && [$node1 exists src2] == 0
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial members
            run_cmd $node0 "Node0" zadd src1 10 "m1"
            run_cmd $node0 "Node0" zadd src2 20 "m1"
            wait_for_condition 100 100 {
                [$node1 zscore src1 "m1"] == 10 &&
                [$node1 zscore src2 "m1"] == 20
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Execute ZUNIONSTORE and ZINTERSTORE on Node 0 with AGGREGATE MIN
            assert_equal 1 [run_cmd $node0 "Node0" zunionstore dst_union 2 src1 src2 aggregate min]
            assert_equal 1 [run_cmd $node0 "Node0" zinterstore dst_inter 2 src1 src2 aggregate min]

            # 4. Execute ZUNIONSTORE and ZINTERSTORE on Node 1 with AGGREGATE MAX
            assert_equal 1 [run_cmd $node1 "Node1" zunionstore dst_union 2 src1 src2 aggregate max]
            assert_equal 1 [run_cmd $node1 "Node1" zinterstore dst_inter 2 src1 src2 aggregate max]

            # 5. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify convergence:
            # Both nodes must agree on the same score for "m1" in both destination sets.
            wait_for_condition 100 100 {
                [$node0 zscore dst_union "m1"] == [$node1 zscore dst_union "m1"] &&
                [$node0 zscore dst_inter "m1"] == [$node1 zscore dst_inter "m1"]
            } else {
                set union0 [$node0 zscore dst_union "m1"]
                set union1 [$node1 zscore dst_union "m1"]
                set inter0 [$node0 zscore dst_inter "m1"]
                set inter1 [$node1 zscore dst_inter "m1"]
                fail "CRDT Zset ZUNIONSTORE/ZINTERSTORE failed to converge: union0=$union0 union1=$union1 inter0=$inter0 inter1=$inter1"
            }

            set union0 [run_cmd $node0 "Node0" zscore dst_union "m1"]
            set union1 [run_cmd $node1 "Node1" zscore dst_union "m1"]
            assert_equal $union0 $union1

            set inter0 [run_cmd $node0 "Node0" zscore dst_inter "m1"]
            set inter1 [run_cmd $node1 "Node1" zscore dst_inter "m1"]
            assert_equal $inter0 $inter1
        }

        test {CRDT Zset: Conditional ZADD options GT and LT during partition} {
            # Clear key and setup initial member
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1"
            wait_for_condition 100 100 {
                [$node1 zscore mm:zset "m1"] == 10
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0: ZADD mm:zset GT 15 "m1"
            run_cmd $node0 "Node0" zadd mm:zset gt 15 "m1"

            # 3. Node 1: ZADD mm:zset LT 8 "m1"
            run_cmd $node1 "Node1" zadd mm:zset lt 8 "m1"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify member "m1" converges to identical score on both nodes.
            wait_for_condition 100 100 {
                [$node0 zscore mm:zset "m1"] == [$node1 zscore mm:zset "m1"]
            } else {
                set val0 [$node0 zscore mm:zset "m1"]
                set val1 [$node1 zscore mm:zset "m1"]
                fail "CRDT Zset conditional ZADD failed to converge: node0=$val0 node1=$val1"
            }

            set val0 [run_cmd $node0 "Node0" zscore mm:zset "m1"]
            set val1 [run_cmd $node1 "Node1" zscore mm:zset "m1"]
            assert_equal $val0 $val1
        }

        test {CRDT Zset: Concurrent ZREMRANGEBYRANK with score changes during partition} {
            # Clear key and setup initial members
            run_cmd $node0 "Node0" del mm:zset
            run_cmd $node0 "Node0" zadd mm:zset 10 "m1" 20 "m2" 30 "m3" 40 "m4"
            wait_for_condition 100 100 {
                [$node1 zcard mm:zset] == 4
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0: ZREMRANGEBYRANK mm:zset 0 1 (removes members at rank 0 and 1, currently m1 and m2)
            run_cmd $node0 "Node0" zremrangebyrank mm:zset 0 1

            # 3. Node 1: Update score of m3 to 5 (shifts ranks so rank 0 is m3, rank 1 is m1)
            run_cmd $node1 "Node1" zadd mm:zset 5 "m3"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify sorted set converges to identical state
            wait_for_condition 100 100 {
                [$node0 zcard mm:zset] == [$node1 zcard mm:zset] &&
                [$node0 zrange mm:zset 0 -1 WITHSCORES] eq [$node1 zrange mm:zset 0 -1 WITHSCORES]
            } else {
                set range0 [$node0 zrange mm:zset 0 -1 WITHSCORES]
                set range1 [$node1 zrange mm:zset 0 -1 WITHSCORES]
                fail "CRDT Zset ZREMRANGEBYRANK convergence failed: node0=$range0 node1=$range1"
            }

            set range0 [run_cmd $node0 "Node0" zrange mm:zset 0 -1 WITHSCORES]
            set range1 [run_cmd $node1 "Node1" zrange mm:zset 0 -1 WITHSCORES]
            assert_equal $range0 $range1
        }
    }
}
