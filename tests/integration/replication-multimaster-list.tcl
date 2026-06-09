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
                "*LPUSH / RPUSH*" { return "'mm:list' = 'orange initial_item banana'" }
                "*LPOP / RPOP*" { return "'mm:list' = 'c'" }
                "*modification (LSET) during partition" { return "'mm:list' = 'a b_from_node0 c'" }
                "*insert and remove (LINSERT / LREM)*" { return "'mm:list' = 'a x c'" }
                "*same end (LPUSH)*" { return "'mm:list' = 'apple orange initial_item'" }
                "*LSET*different indices*" { return "'mm:list' = 'a_node1 b c_node0'" }
                "*LREM*different elements*" { return "'mm:list' = 'b'" }
                "*LPUSH and LPOP*" { return "'mm:list' = 'x b c'" }
                "*insertions at different positions*" { return "'mm:list' = 'a x b y c'" }
                "*trim (LTRIM)*" { return "'mm:list' = 'b c d'" }
                "*LPUSHX and RPUSHX*" { return "'mm:list' = 'l_item initial_item r_item'" }
                "*LREM*duplicate elements*" { return "'mm:list' = 'b a c d'" }
                "*Concurrent LMOVE during partition" { return "'mm:list_src' = 'b'\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:list_dst' = 'a c'" }
                "*RPOPLPUSH*" { return "'mm:list_src' = 'new_item a b'\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:list_dst' = 'c z'" }
                "*Empty list deletion*" { return "'mm:list' = 'c'" }
                "*multi-element pushing*" { return "'mm:list' = 'a b c d e'" }
                "*Out-of-bounds LSET*" { return "'mm:list' = 'a b'" }
                "*duplicate anchor elements*" { return "'mm:list' = 'a x b y c b d'" }
                "*LMOVE and LREM*" { return "'mm:list_src' = 'b'\n\u001b\[32;1mInfo:\u001b\[0m Node post-sync -> 'mm:list_dst' = 'a'" }
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

        # Get current dbid selected by the test suite
        set client_info [$node0 client info]
        set dbid 0
        regexp {db=([0-9]+)} $client_info _ dbid

        test {CRDT List: Concurrent pushes to opposite ends (LPUSH / RPUSH) during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:list
            wait_for_condition 100 100 {
                [$node1 get mm:list] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial list element
            run_cmd $node0 "Node0" rpush mm:list "initial_item"
            wait_for_condition 100 100 {
                [$node1 lindex mm:list 0] eq "initial_item"
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Write concurrently on Node 1: LPUSH orange
            run_cmd $node1 "Node1" lpush mm:list "orange"

            # 4. Write concurrently on Node 0: RPUSH banana
            run_cmd $node0 "Node0" rpush mm:list "banana"

            # 5. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LPUSH/RPUSH merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert {[lsearch $list0 "orange"] != -1}
            assert {[lsearch $list0 "banana"] != -1}
            assert {[lsearch $list0 "initial_item"] != -1}
        }

        test {CRDT List: Concurrent Pop operations (LPOP / RPOP) with count during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c" "d" "e"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 5
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Pop left count 2 on Node 1: LPOP (removes "a", "b")
            assert_equal {a b} [run_cmd $node1 "Node1" lpop mm:list 2]

            # 3. Pop right count 2 on Node 0: RPOP (removes "d", "e")
            assert_equal {e d} [run_cmd $node0 "Node0" rpop mm:list 2]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 1 &&
                [$node1 llen mm:list] == 1
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LPOP/RPOP merge failed (expected length 1): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {c} $list0
        }

        test {CRDT List: Concurrent element modification (LSET) during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Modify index 1 on Node 1: LSET index 1 -> "b_from_node1"
            run_cmd $node1 "Node1" lset mm:list 1 "b_from_node1"

            # 3. Modify index 1 on Node 0: LSET index 1 -> "b_from_node0"
            after 100
            run_cmd $node0 "Node0" lset mm:list 1 "b_from_node0"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify LWW conflict resolution on index 1
            wait_for_condition 100 100 {
                [$node0 lindex mm:list 1] eq "b_from_node0" &&
                [$node1 lindex mm:list 1] eq "b_from_node0"
            } else {
                fail "CRDT List LSET resolution failed: node0=[$node0 lrange mm:list 0 -1] node1=[$node1 lrange mm:list 0 -1]"
            }
        }

        test {CRDT List: Concurrent insert and remove (LINSERT / LREM) during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Insert element on Node 1: LINSERT before "b" insert "x"
            run_cmd $node1 "Node1" linsert mm:list BEFORE "b" "x"

            # 3. Remove element on Node 0: LREM "b"
            run_cmd $node0 "Node0" lrem mm:list 1 "b"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LINSERT/LREM merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {a x c} $list0
        }

        test {CRDT List: Concurrent pushes to the same end (LPUSH) during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "initial_item"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 1
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Write concurrently on Node 1: LPUSH orange
            run_cmd $node1 "Node1" lpush mm:list "orange"

            # 3. Write concurrently on Node 0: LPUSH apple
            run_cmd $node0 "Node0" lpush mm:list "apple"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LPUSH/LPUSH merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert {[lsearch $list0 "orange"] != -1}
            assert {[lsearch $list0 "apple"] != -1}
            assert {[lsearch $list0 "initial_item"] != -1}
        }

        test {CRDT List: Concurrent element modification (LSET) on different indices during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Modify index 0 on Node 1: LSET index 0 -> "a_node1"
            run_cmd $node1 "Node1" lset mm:list 0 "a_node1"

            # 3. Modify index 2 on Node 0: LSET index 2 -> "c_node0"
            run_cmd $node0 "Node0" lset mm:list 2 "c_node0"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 lindex mm:list 0] eq "a_node1" &&
                [$node0 lindex mm:list 2] eq "c_node0" &&
                [$node1 lindex mm:list 0] eq "a_node1" &&
                [$node1 lindex mm:list 2] eq "c_node0"
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LSET on different indices failed: node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
        }

        test {CRDT List: Concurrent remove (LREM) of different elements during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Remove "a" on Node 1
            run_cmd $node1 "Node1" lrem mm:list 1 "a"

            # 3. Remove "c" on Node 0
            run_cmd $node0 "Node0" lrem mm:list 1 "c"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 1 &&
                [$node1 llen mm:list] == 1
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LREM merge failed (expected length 1): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {b} $list0
        }

        test {CRDT List: Concurrent LPUSH and LPOP during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. LPUSH "x" on Node 0 (results in ["x", "a", "b", "c"])
            run_cmd $node0 "Node0" lpush mm:list "x"

            # 3. LPOP on Node 1 (removes "a", results in ["b", "c"])
            assert_equal "a" [run_cmd $node1 "Node1" lpop mm:list]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LPUSH/LPOP merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {x b c} $list0
        }

        test {CRDT List: Concurrent insertions at different positions (LINSERT) during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 3
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Insert on Node 1: BEFORE "b" insert "x"
            run_cmd $node1 "Node1" linsert mm:list BEFORE "b" "x"

            # 3. Insert on Node 0: AFTER "b" insert "y"
            run_cmd $node0 "Node0" linsert mm:list AFTER "b" "y"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 5 &&
                [$node1 llen mm:list] == 5
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LINSERT/LINSERT merge failed (expected length 5): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {a x b y c} $list0
        }

        test {CRDT List: Concurrent trim (LTRIM) during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c" "d" "e"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 5
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Trim on Node 1: remove first element (trim index 1 to -1 -> ["b", "c", "d", "e"])
            run_cmd $node1 "Node1" ltrim mm:list 1 -1

            # 3. Trim on Node 0: remove last element (trim index 0 to 3 -> ["a", "b", "c", "d"])
            run_cmd $node0 "Node0" ltrim mm:list 0 3

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LTRIM merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {b c d} $list0
        }

        test {CRDT List: Concurrent LPUSHX and RPUSHX during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "initial_item"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 1
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. RPUSHX on Node 0 (succeeds because key exists)
            assert_equal 2 [run_cmd $node0 "Node0" rpushx mm:list "r_item"]

            # 3. LPUSHX on Node 1 (succeeds because key exists)
            assert_equal 2 [run_cmd $node1 "Node1" lpushx mm:list "l_item"]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 3 &&
                [$node1 llen mm:list] == 3
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LPUSHX/RPUSHX merge failed (expected length 3): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert {[lsearch $list0 "l_item"] != -1}
            assert {[lsearch $list0 "r_item"] != -1}
        }

        test {CRDT List: Concurrent remove (LREM) of duplicate elements during partition} {
            # Clear key and setup initial list with duplicate elements
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "a" "c" "a" "d"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 6
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 1 removes first occurrence of "a"
            assert_equal 1 [run_cmd $node1 "Node1" lrem mm:list 1 "a"]

            # 3. Node 0 removes last occurrence of "a"
            assert_equal 1 [run_cmd $node0 "Node0" lrem mm:list -1 "a"]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            # Under CRDT, both removes apply, leaving only the middle "a" -> ["b", "a", "c", "d"] (length 4).
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 4 &&
                [$node1 llen mm:list] == 4
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List duplicate LREM failed (expected length 4): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {b a c d} $list0
            # Verify the index of the remaining "a"
            assert_equal 1 [run_cmd $node0 "Node0" lpos mm:list "a"]
        }

        test {CRDT List: Concurrent LMOVE during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:list_src mm:list_dst
            run_cmd $node0 "Node0" rpush mm:list_src "a" "b" "c"
            wait_for_condition 100 100 {
                [$node1 llen mm:list_src] == 3 &&
                [$node1 llen mm:list_dst] == 0
            } else {
                fail "Initial lists did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 moves LEFT-to-LEFT: moves "a" to head of mm:list_dst
            assert_equal "a" [run_cmd $node0 "Node0" lmove mm:list_src mm:list_dst LEFT LEFT]

            # 3. Node 1 moves RIGHT-to-RIGHT: moves "c" to tail of mm:list_dst
            assert_equal "c" [run_cmd $node1 "Node1" lmove mm:list_src mm:list_dst RIGHT RIGHT]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            # Under CRDT:
            # - source list should become ["b"] (length 1)
            # - destination list should have both "a" and "c" (length 2)
            wait_for_condition 120 100 {
                [$node0 llen mm:list_src] == 1 &&
                [$node1 llen mm:list_src] == 1 &&
                [$node0 llen mm:list_dst] == 2 &&
                [$node1 llen mm:list_dst] == 2
            } else {
                set src0 [$node0 lrange mm:list_src 0 -1]
                set dst0 [$node0 lrange mm:list_dst 0 -1]
                set src1 [$node1 lrange mm:list_src 0 -1]
                set dst1 [$node1 lrange mm:list_dst 0 -1]
                fail "CRDT List LMOVE failed: src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" lrange mm:list_src 0 -1]
            set dst0 [run_cmd $node0 "Node0" lrange mm:list_dst 0 -1]
            set src1 [run_cmd $node1 "Node1" lrange mm:list_src 0 -1]
            set dst1 [run_cmd $node1 "Node1" lrange mm:list_dst 0 -1]
            assert_equal $src0 $src1
            assert_equal $dst0 $dst1
            assert_equal {b} $src0
            assert {[lsearch $dst0 "a"] != -1}
            assert {[lsearch $dst0 "c"] != -1}
        }

        test {CRDT List: Concurrent RPOPLPUSH during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:list_src mm:list_dst
            run_cmd $node0 "Node0" rpush mm:list_src "a" "b" "c"
            run_cmd $node0 "Node0" rpush mm:list_dst "z"
            wait_for_condition 100 100 {
                [$node1 llen mm:list_src] == 3 &&
                [$node1 llen mm:list_dst] == 1
            } else {
                fail "Initial lists did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 pops tail and prepends: moves "c"
            assert_equal "c" [run_cmd $node0 "Node0" rpoplpush mm:list_src mm:list_dst]

            # 3. Node 1 prepends a new item to source list
            run_cmd $node1 "Node1" lpush mm:list_src "new_item"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            # Under CRDT:
            # - source list should have "new_item", "a", "b" (length 3, since "c" was popped)
            # - destination list should have "c", "z" (length 2)
            wait_for_condition 120 100 {
                [$node0 llen mm:list_src] == 3 &&
                [$node1 llen mm:list_src] == 3 &&
                [$node0 llen mm:list_dst] == 2 &&
                [$node1 llen mm:list_dst] == 2
            } else {
                set src0 [$node0 lrange mm:list_src 0 -1]
                set dst0 [$node0 lrange mm:list_dst 0 -1]
                set src1 [$node1 lrange mm:list_src 0 -1]
                set dst1 [$node1 lrange mm:list_dst 0 -1]
                fail "CRDT List RPOPLPUSH failed: src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" lrange mm:list_src 0 -1]
            set dst0 [run_cmd $node0 "Node0" lrange mm:list_dst 0 -1]
            set src1 [run_cmd $node1 "Node1" lrange mm:list_src 0 -1]
            set dst1 [run_cmd $node1 "Node1" lrange mm:list_dst 0 -1]
            assert_equal $src0 $src1
            assert_equal $dst0 $dst1
            assert {[lsearch $src0 "new_item"] != -1}
            assert {[lsearch $src0 "c"] == -1}
            assert_equal {c z} $dst0
        }

        test {CRDT List: Empty list deletion vs concurrent push during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 2
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 1 pops all elements to empty the list (triggering deletion/cleanup)
            assert_equal {a b} [run_cmd $node1 "Node1" lpop mm:list 2]
            assert_equal 0 [run_cmd $node1 "Node1" exists mm:list]

            # 3. Node 0 pushes a new element concurrently
            run_cmd $node0 "Node0" rpush mm:list "c"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence: the list should contain only "c"
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 1 &&
                [$node1 llen mm:list] == 1
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List empty list deletion vs concurrent push failed: node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {c} $list0
        }

        test {CRDT List: Concurrent multi-element pushing during partition} {
            # Clear key and setup initial list
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 1
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 1 pushes multiple elements to the tail
            run_cmd $node1 "Node1" rpush mm:list "b" "c"

            # 3. Node 0 pushes multiple elements to the tail
            run_cmd $node0 "Node0" rpush mm:list "d" "e"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence: should have length 5 and be identical
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 5 &&
                [$node1 llen mm:list] == 5
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List concurrent multi-element push failed: node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert {[lsearch $list0 "a"] != -1}
            assert {[lsearch $list0 "b"] != -1}
            assert {[lsearch $list0 "c"] != -1}
            assert {[lsearch $list0 "d"] != -1}
            assert {[lsearch $list0 "e"] != -1}
        }

        test {CRDT List: Out-of-bounds LSET during concurrent trimming} {
            # Clear key and setup initial list of 5 elements
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c" "d" "e"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 5
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 1 trims the list to 2 elements (retaining indices 0 and 1)
            run_cmd $node1 "Node1" ltrim mm:list 0 1

            # 3. Node 0 modifies index 3 (valid on Node 0 during partition)
            run_cmd $node0 "Node0" lset mm:list 3 "d_modified"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence:
            # The elements at indices 2, 3, 4 were deleted by the trim.
            # The LSET on index 3 (which was deleted) should not resurrect the element.
            # The list should converge to length 2 containing {a b}.
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 2 &&
                [$node1 llen mm:list] == 2
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List LSET during concurrent trimming failed: node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {a b} $list0
        }

        test {CRDT List: LINSERT with duplicate anchor elements during partition} {
            # Clear key and setup initial list with duplicate elements
            run_cmd $node0 "Node0" del mm:list
            run_cmd $node0 "Node0" rpush mm:list "a" "b" "c" "b" "d"
            wait_for_condition 100 100 {
                [$node1 llen mm:list] == 5
            } else {
                fail "Initial list did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 inserts "x" BEFORE the first "b"
            run_cmd $node0 "Node0" linsert mm:list BEFORE "b" "x"

            # 3. Node 1 inserts "y" AFTER the first "b"
            run_cmd $node1 "Node1" linsert mm:list AFTER "b" "y"

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT List convergence
            # A correct CRDT list must preserve both concurrent inserts:
            # "x" inserted BEFORE "b" and "y" inserted AFTER "b" are non-conflicting
            # relative positions on the same anchor — both must survive the merge.
            wait_for_condition 100 100 {
                [$node0 llen mm:list] == 7 &&
                [$node1 llen mm:list] == 7
            } else {
                set list0 [$node0 lrange mm:list 0 -1]
                set list1 [$node1 lrange mm:list 0 -1]
                fail "CRDT List duplicate anchor LINSERT failed (expected length 7): node0=$list0 node1=$list1"
            }

            set list0 [run_cmd $node0 "Node0" lrange mm:list 0 -1]
            set list1 [run_cmd $node1 "Node1" lrange mm:list 0 -1]
            assert_equal $list0 $list1
            assert_equal {a x b y c b d} $list0
        }

        test {CRDT List: Concurrent LMOVE and LREM during partition} {
            # Clear source and destination keys
            run_cmd $node0 "Node0" del mm:list_src mm:list_dst
            run_cmd $node0 "Node0" rpush mm:list_src "a" "b"
            wait_for_condition 100 100 {
                [$node1 llen mm:list_src] == 2 &&
                [$node1 llen mm:list_dst] == 0
            } else {
                fail "Initial lists did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 moves "a" to destination
            assert_equal "a" [run_cmd $node0 "Node0" lmove mm:list_src mm:list_dst LEFT LEFT]

            # 3. Node 1 removes "a" from source
            assert_equal 1 [run_cmd $node1 "Node1" lrem mm:list_src 1 "a"]

            # 4. Heal partition by reconnecting links
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify lists converge to the identical state
            # A correct CRDT must treat LMOVE as atomic: "a" is removed from src
            # and added to dst as one unit. LREM on Node1 also removes "a" from src.
            # The add-to-dst (LMOVE) must win over the standalone SREM, so dst={a}, src={b}.
            wait_for_condition 120 100 {
                [$node0 llen mm:list_src] == 1 &&
                [$node1 llen mm:list_src] == 1 &&
                [$node0 llen mm:list_dst] == 1 &&
                [$node1 llen mm:list_dst] == 1
            } else {
                set src0 [$node0 lrange mm:list_src 0 -1]
                set dst0 [$node0 lrange mm:list_dst 0 -1]
                set src1 [$node1 lrange mm:list_src 0 -1]
                set dst1 [$node1 lrange mm:list_dst 0 -1]
                fail "CRDT List LMOVE/LREM failed (expected src={b} dst={a}): src0=$src0 dst0=$dst0 src1=$src1 dst1=$dst1"
            }

            set src0 [run_cmd $node0 "Node0" lrange mm:list_src 0 -1]
            set dst0 [run_cmd $node0 "Node0" lrange mm:list_dst 0 -1]
            set src1 [run_cmd $node1 "Node1" lrange mm:list_src 0 -1]
            set dst1 [run_cmd $node1 "Node1" lrange mm:list_dst 0 -1]
            assert_equal $src0 $src1
            assert_equal $dst0 $dst1
            assert_equal {b} $src0
            assert_equal {a} $dst0
        }
    }
}

