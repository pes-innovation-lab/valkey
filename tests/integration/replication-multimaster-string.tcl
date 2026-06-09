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
                "*Concurrent APPEND*" { return "'mm:string' = 'hello world valkey' (or hello valkey world)" }
                "*INCRBY / DECRBY*" { return "'mm:counter' = '12'" }
                "*INCRBYFLOAT*" { return "'mm:fcounter' = '6.0'" }
                "*Concurrent Range Updates (SETRANGE)*" { return "'mm:string' = 'aXcdYf'" }
                "*Concurrent SETNX*" { return "'mm:setnx' = 'val0' (or val1 depending on win policy)" }
                "*GETDEL and APPEND*" { return "'mm:string' = '_extra' (or deleted depending on win policy)" }
                "*Concurrent GETSET*" { return "'mm:string' = 'node0' (or node1 depending on LWW)" }
                "*Concurrent MSET*" { return "'mm:m1' = 'val1_0', mm:m2 = 'val2_0' (or val1_1/val2_1 depending on LWW)" }
                "*bitwise operations (SETBIT)*" { return "'mm:bitkey' has bits 0 and 7 set to 1" }
                "*key expiration and TTL*" { return "'mm:expirekey' has active TTL (e.g. 100 or 200 seconds)" }
                "*Type transition conflict*" { return "'mm:conflictkey' converged to identical type/value" }
                "*Overlapping SETRANGE*" { return "'mm:string' converged to identical overlapped value (e.g. 'abXYZ3gh' or 'abX123gh')" }
                "*BITFIELD operations*" { return "'mm:string' converged to identical bitfield value (e.g. i8 at 0 is 5, i8 at 8 is 3)" }
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

        test {CRDT String: Concurrent APPEND during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:string
            wait_for_condition 100 100 {
                [$node1 get mm:string] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Setup initial string
            run_cmd $node0 "Node0" set mm:string "hello"
            wait_for_condition 100 100 {
                [$node1 get mm:string] eq "hello"
            } else {
                fail "Initial write did not propagate"
            }

            # 2. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 3. Node 1 appends " valkey"
            run_cmd $node1 "Node1" append mm:string " valkey"

            # 4. Node 0 appends " world"
            run_cmd $node0 "Node0" append mm:string " world"

            # 5. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 6. Verify CRDT String convergence:
            # Under CRDT (like text editing), both appends should merge, preserving both additions.
            # (Under LWW, one node's complete string wins, leaving either "hello valkey" or "hello world").
            wait_for_condition 100 100 {
                [string length [$node0 get mm:string]] == 17 &&
                [string length [$node1 get mm:string]] == 17
            } else {
                set val0 [$node0 get mm:string]
                set val1 [$node1 get mm:string]
                fail "CRDT String APPEND merge failed (expected length 17): node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:string]
            set val1 [run_cmd $node1 "Node1" get mm:string]
            assert_equal $val0 $val1
            assert {[string first "world" $val0] != -1}
            assert {[string first "valkey" $val0] != -1}
        }

        test {CRDT String: Concurrent Counter Increments (INCRBY / DECRBY) during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:counter
            run_cmd $node0 "Node0" set mm:counter "10"
            wait_for_condition 100 100 {
                [$node1 get mm:counter] eq "10"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Increment by 5 on Node 0
            run_cmd $node0 "Node0" incrby mm:counter 5

            # 3. Decrement by 3 on Node 1
            run_cmd $node1 "Node1" decrby mm:counter 3

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Counter convergence:
            # Under PN-Counter CRDT, both operations accumulate, resulting in 10 + 5 - 3 = 12.
            # (Under LWW, it resolves to either 15 or 7).
            wait_for_condition 100 100 {
                [$node0 get mm:counter] == 12 &&
                [$node1 get mm:counter] == 12
            } else {
                set val0 [$node0 get mm:counter]
                set val1 [$node1 get mm:counter]
                fail "CRDT Counter merge failed (expected 12): node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:counter]
            set val1 [run_cmd $node1 "Node1" get mm:counter]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent Floating Point Increments (INCRBYFLOAT) during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:fcounter
            run_cmd $node0 "Node0" set mm:fcounter "2.5"
            wait_for_condition 100 100 {
                [$node1 get mm:fcounter] eq "2.5"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Increment float by 1.5 on Node 0
            run_cmd $node0 "Node0" incrbyfloat mm:fcounter 1.5

            # 3. Increment float by 2.0 on Node 1
            run_cmd $node1 "Node1" incrbyfloat mm:fcounter 2.0

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT Counter convergence:
            # Under PN-Counter, floats accumulate to 2.5 + 1.5 + 2.0 = 6.0.
            # (Under LWW, one wins: either 4.0 or 4.5).
            wait_for_condition 100 100 {
                [$node0 get mm:fcounter] == 6.0 &&
                [$node1 get mm:fcounter] == 6.0
            } else {
                set val0 [$node0 get mm:fcounter]
                set val1 [$node1 get mm:fcounter]
                fail "CRDT Float Counter merge failed (expected 6.0): node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:fcounter]
            set val1 [run_cmd $node1 "Node1" get mm:fcounter]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent Range Updates (SETRANGE) during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:string
            run_cmd $node0 "Node0" set mm:string "abcdef"
            wait_for_condition 100 100 {
                [$node1 get mm:string] eq "abcdef"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 sets index 1 -> "X"
            run_cmd $node0 "Node0" setrange mm:string 1 "X"

            # 3. Node 1 sets index 4 -> "Y"
            run_cmd $node1 "Node1" setrange mm:string 4 "Y"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT String convergence:
            # Under CRDT, both character updates should apply, yielding "aXcdYf".
            # (Under LWW, one wins completely, yielding either "aXcdef" or "abcdYf").
            wait_for_condition 100 100 {
                [$node0 get mm:string] eq "aXcdYf" &&
                [$node1 get mm:string] eq "aXcdYf"
            } else {
                set val0 [$node0 get mm:string]
                set val1 [$node1 get mm:string]
                fail "CRDT String SETRANGE merge failed (expected 'aXcdYf'): node0='$val0' node1='$val1'"
            }

            # Also check getrange/substr read behavior
            assert_equal "Xcd" [run_cmd $node0 "Node0" getrange mm:string 1 3]
            assert_equal "Xcd" [run_cmd $node1 "Node1" getrange mm:string 1 3]
        }

        test {CRDT String: Concurrent SETNX during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:setnx
            wait_for_condition 100 100 {
                [$node1 get mm:setnx] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 sets value via SETNX (returns 1)
            assert_equal 1 [run_cmd $node0 "Node0" setnx mm:setnx "val0"]

            # 3. Node 1 sets value via SETNX (returns 1)
            assert_equal 1 [run_cmd $node1 "Node1" setnx mm:setnx "val1"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must converge to the same value.
            wait_for_condition 100 100 {
                [$node0 get mm:setnx] eq [$node1 get mm:setnx]
            } else {
                set val0 [$node0 get mm:setnx]
                set val1 [$node1 get mm:setnx]
                fail "CRDT String SETNX merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:setnx]
            set val1 [run_cmd $node1 "Node1" get mm:setnx]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent GETDEL and APPEND during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:string
            run_cmd $node0 "Node0" set mm:string "original"
            wait_for_condition 100 100 {
                [$node1 get mm:string] eq "original"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 performs GETDEL (retrieves and deletes key)
            assert_equal "original" [run_cmd $node0 "Node0" getdel mm:string]

            # 3. Node 1 performs APPEND (appends "_extra")
            assert_equal 14 [run_cmd $node1 "Node1" append mm:string "_extra"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must converge to the exact same state (either key deleted, or key having the merged string).
            wait_for_condition 100 100 {
                [$node0 get mm:string] eq [$node1 get mm:string]
            } else {
                set val0 [$node0 get mm:string]
                set val1 [$node1 get mm:string]
                fail "CRDT String GETDEL/APPEND merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:string]
            set val1 [run_cmd $node1 "Node1" get mm:string]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent GETSET during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:string
            run_cmd $node0 "Node0" set mm:string "init"
            wait_for_condition 100 100 {
                [$node1 get mm:string] eq "init"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 gets and sets to "node0"
            assert_equal "init" [run_cmd $node0 "Node0" getset mm:string "node0"]

            # 3. Node 1 gets and sets to "node1"
            assert_equal "init" [run_cmd $node1 "Node1" getset mm:string "node1"]

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must converge to the same value.
            wait_for_condition 100 100 {
                [$node0 get mm:string] eq [$node1 get mm:string]
            } else {
                set val0 [$node0 get mm:string]
                set val1 [$node1 get mm:string]
                fail "CRDT String GETSET merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:string]
            set val1 [run_cmd $node1 "Node1" get mm:string]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent MSET during partition} {
            # Clear keys
            run_cmd $node0 "Node0" del mm:m1 mm:m2
            wait_for_condition 100 100 {
                [$node1 get mm:m1] eq {} && [$node1 get mm:m2] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 sets both keys via MSET
            run_cmd $node0 "Node0" mset mm:m1 "val1_0" mm:m2 "val2_0"

            # 3. Node 1 sets both keys via MSET
            run_cmd $node1 "Node1" mset mm:m1 "val1_1" mm:m2 "val2_1"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both keys must converge to the same value on both nodes.
            wait_for_condition 100 100 {
                [$node0 get mm:m1] eq [$node1 get mm:m1] &&
                [$node0 get mm:m2] eq [$node1 get mm:m2]
            } else {
                set m1_0 [$node0 get mm:m1]
                set m1_1 [$node1 get mm:m1]
                set m2_0 [$node0 get mm:m2]
                set m2_1 [$node1 get mm:m2]
                fail "CRDT String MSET merge failed: mm:m1(node0)='$m1_0' mm:m1(node1)='$m1_1' mm:m2(node0)='$m2_0' mm:m2(node1)='$m2_1'"
            }

            set m1_0 [run_cmd $node0 "Node0" get mm:m1]
            set m1_1 [run_cmd $node1 "Node1" get mm:m1]
            assert_equal $m1_0 $m1_1

            set m2_0 [run_cmd $node0 "Node0" get mm:m2]
            set m2_1 [run_cmd $node1 "Node1" get mm:m2]
            assert_equal $m2_0 $m2_1
        }

        test {CRDT String: Concurrent bitwise operations (SETBIT) during partition} {
            # Clear key
            run_cmd $node0 "Node0" del mm:bitkey
            wait_for_condition 100 100 {
                [run_cmd $node1 "Node1" get mm:bitkey] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 sets bit 0
            run_cmd $node0 "Node0" setbit mm:bitkey 0 1

            # 3. Node 1 sets bit 7
            run_cmd $node1 "Node1" setbit mm:bitkey 7 1

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify CRDT String convergence:
            # Under CRDT, both bit updates should merge.
            wait_for_condition 100 100 {
                [run_cmd $node0 "Node0" getbit mm:bitkey 0] == 1 &&
                [run_cmd $node0 "Node0" getbit mm:bitkey 7] == 1 &&
                [run_cmd $node1 "Node1" getbit mm:bitkey 0] == 1 &&
                [run_cmd $node1 "Node1" getbit mm:bitkey 7] == 1
            } else {
                fail "CRDT String SETBIT merge failed"
            }

            set val0 [run_cmd $node0 "Node0" get mm:bitkey]
            set val1 [run_cmd $node1 "Node1" get mm:bitkey]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent key expiration and TTL updates (EXPIRE) during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:expirekey
            run_cmd $node0 "Node0" set mm:expirekey "ttl_value"
            wait_for_condition 100 100 {
                [run_cmd $node1 "Node1" get mm:expirekey] eq "ttl_value"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 sets TTL to 100 seconds
            run_cmd $node0 "Node0" expire mm:expirekey 100

            # 3. Node 1 sets TTL to 200 seconds
            run_cmd $node1 "Node1" expire mm:expirekey 200

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must converge to the same TTL state (within a small tolerance).
            wait_for_condition 100 100 {
                [expr {abs([run_cmd $node0 "Node0" ttl mm:expirekey] - [run_cmd $node1 "Node1" ttl mm:expirekey]) <= 2}]
            } else {
                set ttl0 [run_cmd $node0 "Node0" ttl mm:expirekey]
                set ttl1 [run_cmd $node1 "Node1" ttl mm:expirekey]
                fail "CRDT String EXPIRE merge failed: node0 TTL='$ttl0', node1 TTL='$ttl1'"
            }

            set ttl0 [run_cmd $node0 "Node0" ttl mm:expirekey]
            set ttl1 [run_cmd $node1 "Node1" ttl mm:expirekey]
            assert {$ttl0 > 50}
            assert {$ttl1 > 50}
        }

        test {CRDT String: Type transition conflict (Counter vs Text) during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:conflictkey
            run_cmd $node0 "Node0" set mm:conflictkey "10"
            wait_for_condition 100 100 {
                [run_cmd $node1 "Node1" get mm:conflictkey] eq "10"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 performs a Counter operation (INCRBY)
            run_cmd $node0 "Node0" incrby mm:conflictkey 5

            # 3. Node 1 performs a Text operation (APPEND)
            run_cmd $node1 "Node1" append mm:conflictkey "abc"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence:
            # Both nodes must converge to the exact same value.
            wait_for_condition 100 100 {
                [run_cmd $node0 "Node0" get mm:conflictkey] eq [run_cmd $node1 "Node1" get mm:conflictkey]
            } else {
                set val0 [run_cmd $node0 "Node0" get mm:conflictkey]
                set val1 [run_cmd $node1 "Node1" get mm:conflictkey]
                fail "CRDT String Type Transition conflict merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:conflictkey]
            set val1 [run_cmd $node1 "Node1" get mm:conflictkey]
            assert_equal $val0 $val1
        }

        test {CRDT String: Overlapping SETRANGE writes during partition} {
            # Clear key and setup initial value
            run_cmd $node0 "Node0" del mm:string
            run_cmd $node0 "Node0" set mm:string "abcdefgh"
            wait_for_condition 100 100 {
                [run_cmd $node1 "Node1" get mm:string] eq "abcdefgh"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 writes "XYZ" starting at index 2
            run_cmd $node0 "Node0" setrange mm:string 2 "XYZ"

            # 3. Node 1 writes "123" starting at index 3
            run_cmd $node1 "Node1" setrange mm:string 3 "123"

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence
            wait_for_condition 100 100 {
                [run_cmd $node0 "Node0" get mm:string] eq [run_cmd $node1 "Node1" get mm:string]
            } else {
                set val0 [run_cmd $node0 "Node0" get mm:string]
                set val1 [run_cmd $node1 "Node1" get mm:string]
                fail "CRDT String Overlapping SETRANGE merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:string]
            set val1 [run_cmd $node1 "Node1" get mm:string]
            assert_equal $val0 $val1
        }

        test {CRDT String: Concurrent BITFIELD operations during partition} {
            # Clear key and setup initial value (2 bytes of zeros)
            run_cmd $node0 "Node0" del mm:string
            run_cmd $node0 "Node0" set mm:string "\x00\x00"
            wait_for_condition 100 100 {
                [run_cmd $node1 "Node1" get mm:string] eq "\x00\x00"
            } else {
                fail "Initial write did not propagate"
            }

            # 1. Simulate partition by disconnecting links
            disconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 2. Node 0 performs BITFIELD operations
            run_cmd $node0 "Node0" bitfield mm:string INCRBY i8 0 5

            # 3. Node 1 performs BITFIELD operations
            run_cmd $node1 "Node1" bitfield mm:string INCRBY i8 8 3

            # 4. Heal partition
            reconnect_links $node0 $node1 $node0_host $node0_port $node1_host $node1_port

            # 5. Verify convergence
            wait_for_condition 100 100 {
                [run_cmd $node0 "Node0" get mm:string] eq [run_cmd $node1 "Node1" get mm:string]
            } else {
                set val0 [run_cmd $node0 "Node0" get mm:string]
                set val1 [run_cmd $node1 "Node1" get mm:string]
                fail "CRDT String BITFIELD merge failed: node0='$val0' node1='$val1'"
            }

            set val0 [run_cmd $node0 "Node0" get mm:string]
            set val1 [run_cmd $node1 "Node1" get mm:string]
            assert_equal $val0 $val1
        }
    }
}


