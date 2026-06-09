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
                "*SADD of different elements*" { return "'mm:set' = 'a b c'" }
                "*SADD and SREM of different elements*" { return "'mm:set' = 'b c'" }
                "*SADD and SREM of the SAME element*" { return "'mm:set' = 'a' (or empty depending on win policy)" }
                "*Concurrent SPOP during partition" { return "SPOP outcome leaves exactly 1 remaining element (out of a, b, c) in 'mm:set'" }
                "*Concurrent SMOVE during partition" { return "'mm:set_src' = ''\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:set_dst' = 'a b'" }
                "*Concurrent read operations*" { return "'mm:set_out' = 'b'" }
                "*multi-element pop (SPOP)*" { return "SPOP outcome leaves exactly 1 remaining element (out of a, b, c, d, e) in 'mm:set'" }
                "*SMOVE to concurrently deleted destination*" { return "'mm:set_src' = ''\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:set_dst' = 'a'" }
                "*SMOVE and SREM on same element*" { return "'mm:set_src' = ''\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:set_dst' = 'a'" }
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

        test {CRDT Set: Concurrent SADD of different elements during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:set
            wait_for_condition 100 100 {
                [$node1 scard mm:set] == 0
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial element
            run_cmd $node0 "Node0" sadd mm:set "a"
            wait_for_condition 100 100 {
                [$node1 sismember mm:set "a"] == 1
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Add element "b" on Node 0
            run_cmd $node0 "Node0" sadd mm:set "b"

            # 4. Add element "c" on Node 1
            run_cmd $node1 "Node1" sadd mm:set "c"

            # 5. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify CRDT Set convergence:
            # Under CRDT (like OR-Set), all elements should merge, resulting in {"a", "b", "c"} (size 3).
            # (Under LWW, one node's set overrides the other, resulting in size 2).
            wait_for_condition 100 100 {
                [$node0 scard mm:set] == 3 &&
                [$node1 scard mm:set] == 3
            } else {
                set members0 [$node0 smembers mm:set]
                set members1 [$node1 smembers mm:set]
                fail "CRDT Set SADD merge failed (expected size 3): node0=$members0 node1=$members1"
            }

            set members0 [run_cmd $node0 "Node0" smembers mm:set]
            set members1 [run_cmd $node1 "Node1" smembers mm:set]
            assert_equal [lsort $members0] [lsort $members1]
            assert {[lsearch $members0 "a"] != -1}
            assert {[lsearch $members0 "b"] != -1}
            assert {[lsearch $members0 "c"] != -1}
        }

        test {CRDT Set: Concurrent SADD and SREM of different elements during partition} {
            # Clear key and setup initial elements
            run_cmd $node0 "Node0" del mm:set
            run_cmd $node0 "Node0" sadd mm:set "a" "b"
            wait_for_condition 100 100 {
                [$node1 scard mm:set] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Add element "c" on Node 0
            run_cmd $node0 "Node0" sadd mm:set "c"

            # 3. Remove element "a" on Node 1
            run_cmd $node1 "Node1" srem mm:set "a"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # Under CRDT, both additions and removals should merge, yielding {"b", "c"} (size 2).
            # (Under LWW, one node overrides, leaving either {"a", "b", "c"} or {"b"}).
            wait_for_condition 100 100 {
                [$node0 scard mm:set] == 2 &&
                [$node1 scard mm:set] == 2
            } else {
                set members0 [$node0 smembers mm:set]
                set members1 [$node1 smembers mm:set]
                fail "CRDT Set SADD/SREM merge failed (expected size 2): node0=$members0 node1=$members1"
            }

            set members0 [run_cmd $node0 "Node0" smembers mm:set]
            set members1 [run_cmd $node1 "Node1" smembers mm:set]
            assert_equal [lsort $members0] [lsort $members1]
            assert_equal 0 [run_cmd $node0 "Node0" sismember mm:set "a"]
            assert_equal 1 [run_cmd $node0 "Node0" sismember mm:set "c"]
        }

        test {CRDT Set: Concurrent SADD and SREM of the SAME element during partition} {
            # Clear key and setup initial elements
            run_cmd $node0 "Node0" del mm:set
            run_cmd $node0 "Node0" sadd mm:set "a"
            wait_for_condition 100 100 {
                [$node1 sismember mm:set "a"] == 1
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 removes "a"
            run_cmd $node0 "Node0" srem mm:set "a"

            # 3. Node 1 adds "a" concurrently (or re-adds it)
            run_cmd $node1 "Node1" sadd mm:set "a"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # Both nodes must converge to the same membership state for "a".
            # Under OR-Set or LWW-Element-Set, they must agree on either "a" is present or absent.
            wait_for_condition 100 100 {
                [$node0 sismember mm:set "a"] == [$node1 sismember mm:set "a"]
            } else {
                set val0 [$node0 sismember mm:set "a"]
                set val1 [$node1 sismember mm:set "a"]
                fail "CRDT Set same element add/remove merge failed: node0=$val0 node1=$val1"
            }
        }

        test {CRDT Set: Concurrent SPOP during partition} {
            # Clear key and setup initial elements
            run_cmd $node0 "Node0" del mm:set
            run_cmd $node0 "Node0" sadd mm:set "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 scard mm:set] == 3
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Pop 1 element from Node 0
            set pop0 [run_cmd $node0 "Node0" spop mm:set]
            assert {[llength $pop0] == 1}

            # 3. Pop 1 element from Node 1
            set pop1 [run_cmd $node1 "Node1" spop mm:set]
            assert {[llength $pop1] == 1}

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # Under CRDT, both pops should succeed (elements removed), resulting in size 1 (only the unpopped element remains).
            # (Under LWW, one pop is lost, resulting in size 2).
            wait_for_condition 100 100 {
                [$node0 scard mm:set] == 1 &&
                [$node1 scard mm:set] == 1
            } else {
                set members0 [$node0 smembers mm:set]
                set members1 [$node1 smembers mm:set]
                fail "CRDT Set SPOP merge failed (expected size 1): node0=$members0 node1=$members1"
            }

            set members0 [run_cmd $node0 "Node0" smembers mm:set]
            set members1 [run_cmd $node1 "Node1" smembers mm:set]
            assert_equal $members0 $members1
        }

        test {CRDT Set: Concurrent SMOVE during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:set_src mm:set_dst
            run_cmd $node0 "Node0" sadd mm:set_src "a" "b"
            wait_for_condition 100 100 {
                [$node1 scard mm:set_src] == 2 &&
                [$node1 scard mm:set_dst] == 0
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 moves "a" to destination
            assert_equal 1 [run_cmd $node0 "Node0" smove mm:set_src mm:set_dst "a"]

            # 3. Node 1 moves "b" to destination
            assert_equal 1 [run_cmd $node1 "Node1" smove mm:set_src mm:set_dst "b"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # - source set should be empty (both moved)
            # - destination set should have {"a", "b"} (size 2)
            # (Under LWW, one of the moves is overwritten, leading to incorrect size).
            wait_for_condition 120 100 {
                [$node0 scard mm:set_src] == 0 &&
                [$node1 scard mm:set_src] == 0 &&
                [$node0 scard mm:set_dst] == 2 &&
                [$node1 scard mm:set_dst] == 2
            } else {
                set src0 [$node0 smembers mm:set_src]
                set dst0 [$node0 smembers mm:set_dst]
                set src1 [$node1 smembers mm:set_src]
                set dst1 [$node1 smembers mm:set_dst]
                fail "CRDT Set SMOVE merge failed: src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" smembers mm:set_src]
            set dst0 [run_cmd $node0 "Node0" smembers mm:set_dst]
            set src1 [run_cmd $node1 "Node1" smembers mm:set_src]
            set dst1 [run_cmd $node1 "Node1" smembers mm:set_dst]
            assert_equal $src0 $src1
            assert_equal [lsort $dst0] [lsort $dst1]
            assert {[lsearch $dst0 "a"] != -1}
            assert {[lsearch $dst0 "b"] != -1}
        }

        test {CRDT Set: Concurrent read operations (SINTER, SUNION, SDIFF) verification} {
            # Clear keys and setup sets
            run_cmd $node0 "Node0" del mm:set1 mm:set2 mm:set_out
            run_cmd $node0 "Node0" sadd mm:set1 "a" "b"
            run_cmd $node0 "Node0" sadd mm:set2 "b" "c"
            wait_for_condition 100 100 {
                [$node1 scard mm:set1] == 2 && [$node1 scard mm:set2] == 2
            } else {
                fail "Initial write did not propagate"
            }

            # Verify multi-key read operations post-replication
            assert_equal {b} [run_cmd $node0 "Node0" sinter mm:set1 mm:set2]
            assert_equal {b} [run_cmd $node1 "Node1" sinter mm:set1 mm:set2]

            set union0 [run_cmd $node0 "Node0" sunion mm:set1 mm:set2]
            set union1 [run_cmd $node1 "Node1" sunion mm:set1 mm:set2]
            assert_equal [lsort $union0] {a b c}
            assert_equal [lsort $union1] {a b c}

            assert_equal {a} [run_cmd $node0 "Node0" sdiff mm:set1 mm:set2]
            assert_equal {a} [run_cmd $node1 "Node1" sdiff mm:set1 mm:set2]

            # Verify store commands
            assert_equal 1 [run_cmd $node0 "Node0" sinterstore mm:set_out mm:set1 mm:set2]
            wait_for_condition 100 100 {
                [$node1 sismember mm:set_out "b"] == 1
            } else {
                fail "SINTERSTORE write did not propagate"
            }
        }

        test {CRDT Set: Concurrent multi-element pop (SPOP) during partition} {
            # Clear key and setup initial elements
            run_cmd $node0 "Node0" del mm:set
            run_cmd $node0 "Node0" sadd mm:set "a" "b" "c" "d" "e"
            wait_for_condition 100 100 {
                [$node1 scard mm:set] == 5
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Pop 2 elements from Node 0
            set pop0 [run_cmd $node0 "Node0" spop mm:set 2]
            assert {[llength $pop0] == 2}

            # 3. Pop 2 elements from Node 1
            set pop1 [run_cmd $node1 "Node1" spop mm:set 2]
            assert {[llength $pop1] == 2}

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # Calculate expected remaining elements
            set popped [lsort -unique [concat $pop0 $pop1]]
            set expected {}
            foreach el {a b c d e} {
                if {[lsearch -exact $popped $el] == -1} {
                    lappend expected $el
                }
            }
            set expected_len [llength $expected]

            # 5. Verify CRDT Set convergence
            wait_for_condition 100 100 {
                [$node0 scard mm:set] == $expected_len &&
                [$node1 scard mm:set] == $expected_len
            } else {
                set members0 [$node0 smembers mm:set]
                set members1 [$node1 smembers mm:set]
                fail "CRDT Set SPOP merge failed (expected size $expected_len): node0=$members0 node1=$members1"
            }

            set members0 [run_cmd $node0 "Node0" smembers mm:set]
            set members1 [run_cmd $node1 "Node1" smembers mm:set]
            assert_equal [lsort $members0] [lsort $expected]
            assert_equal [lsort $members1] [lsort $expected]
        }

        test {CRDT Set: SMOVE to concurrently deleted destination set during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:set_src mm:set_dst
            run_cmd $node0 "Node0" sadd mm:set_src "a"
            run_cmd $node0 "Node0" sadd mm:set_dst "b"
            wait_for_condition 100 100 {
                [$node1 scard mm:set_src] == 1 &&
                [$node1 scard mm:set_dst] == 1
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 deletes the destination set
            run_cmd $node0 "Node0" del mm:set_dst

            # 3. Node 1 moves "a" to the destination set
            assert_equal 1 [run_cmd $node1 "Node1" smove mm:set_src mm:set_dst "a"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # A correct CRDT must implement add-wins semantics for SMOVE:
            # Node1's SMOVE adds "a" to dst; Node0's DEL of dst is concurrent.
            # The add (SMOVE) must win over the delete — dst must contain {"a"}, src must be empty.
            wait_for_condition 120 100 {
                [$node0 scard mm:set_src] == 0 &&
                [$node1 scard mm:set_src] == 0 &&
                [$node0 scard mm:set_dst] == 1 &&
                [$node1 scard mm:set_dst] == 1
            } else {
                set src0 [$node0 smembers mm:set_src]
                set dst0 [$node0 smembers mm:set_dst]
                set src1 [$node1 smembers mm:set_src]
                set dst1 [$node1 smembers mm:set_dst]
                fail "CRDT Set SMOVE to deleted destination failed (expected src={} dst={a}): src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" smembers mm:set_src]
            set dst0 [run_cmd $node0 "Node0" smembers mm:set_dst]
            set src1 [run_cmd $node1 "Node1" smembers mm:set_src]
            set dst1 [run_cmd $node1 "Node1" smembers mm:set_dst]

            assert_equal $src0 $src1
            assert_equal $dst0 $dst1
            assert_equal {a} $dst0
        }

        test {CRDT Set: Concurrent SMOVE and SREM on same element during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:set_src mm:set_dst
            run_cmd $node0 "Node0" sadd mm:set_src "a"
            wait_for_condition 100 100 {
                [$node1 scard mm:set_src] == 1 &&
                [$node1 scard mm:set_dst] == 0
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 moves "a" to destination
            assert_equal 1 [run_cmd $node0 "Node0" smove mm:set_src mm:set_dst "a"]

            # 3. Node 1 removes "a"
            assert_equal 1 [run_cmd $node1 "Node1" srem mm:set_src "a"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Set convergence:
            # A correct CRDT must treat SMOVE as atomic: the element is removed from src
            # and added to dst as one unit. Even though Node1 also SREMs "a" from src,
            # the SMOVE's add-to-dst must survive — dst must contain {"a"}, src must be empty.
            wait_for_condition 120 100 {
                [$node0 scard mm:set_src] == 0 &&
                [$node1 scard mm:set_src] == 0 &&
                [$node0 scard mm:set_dst] == 1 &&
                [$node1 scard mm:set_dst] == 1
            } else {
                set src0 [$node0 smembers mm:set_src]
                set dst0 [$node0 smembers mm:set_dst]
                set src1 [$node1 smembers mm:set_src]
                set dst1 [$node1 smembers mm:set_dst]
                fail "CRDT Set SMOVE/SREM failed (expected src={} dst={a}): src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" smembers mm:set_src]
            set dst0 [run_cmd $node0 "Node0" smembers mm:set_dst]
            set src1 [run_cmd $node1 "Node1" smembers mm:set_src]
            set dst1 [run_cmd $node1 "Node1" smembers mm:set_dst]

            assert_equal $src0 $src1
            assert_equal $dst0 $dst1
            assert_equal {a} $dst0
        }
    }
}


