start_server {tags {"repl external:skip"} overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
    start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
        set node0 [srv -1 client]
        set node0_host [srv -1 host]
        set node0_port [srv -1 port]
        set node1 [srv 0 client]
        set node1_host [srv 0 host]
        set node1_port [srv 0 port]

        test {Set up active-replica multi-master topology} {
            $node1 replicaof add $node0_host $node0_port
            wait_for_condition 100 100 {
                [s 0 master_link_status] eq {up}
            } else {
                fail "Initial replica link not established"
            }
        }

        # Get current dbid selected by the test suite
        set client_info [$node0 client info]
        set dbid 0
        regexp {db=([0-9]+)} $client_info _ dbid

        # Global counter to ensure unique replay IDs per origin.
        # Use global namespace to safely access it inside the proc.
        global rreplay_id
        set rreplay_id 1000

        proc send_rreplay {node uuid dbid ts args} {
            global rreplay_id
            incr rreplay_id
            $node rreplay $uuid $dbid $rreplay_id $ts {*}$args
            return $rreplay_id
        }

        test {Basic LWW convergence with timestamps} {
            # Enable peer capability on node0 connection to send direct RREPLAY commands
            assert_equal OK [$node0 replconf capa rreplay-peer]
            assert_equal OK [$node0 replconf uuid 1111111111111111111111111111111111111111]

            # Clear keys
            $node0 del mm:lww:t1

            # 1. First write: timestamp 1000
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 1000 set mm:lww:t1 first
            assert_equal {first} [$node0 get mm:lww:t1]

            # 2. Stale write: timestamp 999 (should be ignored)
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 999 set mm:lww:t1 stale
            assert_equal {first} [$node0 get mm:lww:t1]

            # 3. Newer write: timestamp 1001 (should win)
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 1001 set mm:lww:t1 newer
            assert_equal {newer} [$node0 get mm:lww:t1]
        }

        test {LWW tie-breaking using runid and replay_id} {
            # Clear keys
            $node0 del mm:lww:t2

            # Use identical timestamps (2000) to trigger tie-breaker logic.
            # Tie-breaker is formed as <uuid>:<replay_id>.
            # Let uuid_A = 1111... and uuid_B = 3333... (so uuid_B > uuid_A).

            set uuid_A "1111111111111111111111111111111111111111"
            set uuid_B "3333333333333333333333333333333333333333"

            # 1. Write with uuid_A (timestamp 2000, replay_id 1) -> tie-breaker "1111...:1"
            # Note: We hardcode replay_id here because tie-breaking requires control of replay_id structure.
            assert_equal 1 [$node0 rreplay $uuid_A $dbid 1 2000 set mm:lww:t2 val_A]
            assert_equal {val_A} [$node0 get mm:lww:t2]

            # 2. Write with uuid_B (timestamp 2000, replay_id 1) -> tie-breaker "3333...:1" (larger than "1111...:1")
            # Since uuid_B > uuid_A, this write should win.
            assert_equal 1 [$node0 rreplay $uuid_B $dbid 1 2000 set mm:lww:t2 val_B]
            assert_equal {val_B} [$node0 get mm:lww:t2]

            # 3. Write with uuid_A again (timestamp 2000, replay_id 2) -> tie-breaker "1111...:2" (smaller than "3333...:1" lexicographically)
            # This should be ignored because "3333...:1" is lexicographically larger than "1111...:2".
            assert_equal 2 [$node0 rreplay $uuid_A $dbid 2 2000 set mm:lww:t2 val_A_retry]
            assert_equal {val_B} [$node0 get mm:lww:t2]

            # 4. Write with uuid_B (timestamp 2000, replay_id 2) -> tie-breaker "3333...:2" (larger than "3333...:1")
            # This should win.
            assert_equal 2 [$node0 rreplay $uuid_B $dbid 2 2000 set mm:lww:t2 val_B_new]
            assert_equal {val_B_new} [$node0 get mm:lww:t2]
        }

        test {Multi-key RREPLAY command atomic freshness filtering} {
            # For multi-key commands, if any key is not fresh, the entire command is rejected.
            $node0 del mm:multi:k1 mm:multi:k2

            # 1. Stamp k1 with high timestamp 3000
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 3000 set mm:multi:k1 v1_high
            # 2. Stamp k2 with low timestamp 1000
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 1000 set mm:multi:k2 v2_low

            # 3. Send RREPLAY DEL with timestamp 2000.
            # Since k1 (3000) > 2000, k1 is not fresh.
            # This should make the entire DEL command stale/non-fresh and reject it.
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 2000 del mm:multi:k1 mm:multi:k2

            # 4. Check that neither key was deleted
            assert_equal {v1_high} [$node0 get mm:multi:k1]
            assert_equal {v2_low} [$node0 get mm:multi:k2]

            # 5. Send RREPLAY DEL with timestamp 3001. Both keys are now fresh.
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 3001 del mm:multi:k1 mm:multi:k2
            assert_equal {} [$node0 get mm:multi:k1]
            assert_equal {} [$node0 get mm:multi:k2]
        }

        test {MSET partial key filtering} {
            # MSET is handled specially: it filters out stale keys but applies fresh keys.
            $node0 del mm:mset:k1 mm:mset:k2

            # 1. Stamp k1 with high timestamp 3000
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 3000 set mm:mset:k1 v1_high
            # 2. Stamp k2 with low timestamp 1000
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 1000 set mm:mset:k2 v2_low

            # 3. Send RREPLAY MSET with timestamp 2000.
            # k1 (3000 > 2000) should be filtered out.
            # k2 (1000 < 2000) should be updated.
            send_rreplay $node0 2222222222222222222222222222222222222222 $dbid 2000 mset mm:mset:k1 new_v1 mm:mset:k2 new_v2

            # 4. Check results
            assert_equal {v1_high} [$node0 get mm:mset:k1]
            assert_equal {new_v2} [$node0 get mm:mset:k2]
        }

        test {Lamport logical clock sync across active-active nodes} {
            # Reset keys
            $node0 del mm:lamport
            $node1 del mm:lamport

            # Write on node0 to get base clock
            set clock0 [s -1 mvcc_clock]

            # Now, set a very high clock on node1 using a direct RREPLAY command.
            assert_equal OK [$node1 replconf capa rreplay-peer]
            assert_equal OK [$node1 replconf uuid 1111111111111111111111111111111111111111]
            set future_ts [expr {$clock0 + 5000000}]
            send_rreplay $node1 2222222222222222222222222222222222222222 $dbid $future_ts set mm:lamport val_future

            # Wait for mm:lamport to propagate to node0.
            wait_for_condition 100 100 {
                [$node0 get mm:lamport] eq {val_future}
            } else {
                fail "Write from node1 did not propagate to node0"
            }

            # Check that node0's mvcc_clock has updated to at least future_ts!
            set clock0_after [s -1 mvcc_clock]
            assert {$clock0_after >= $future_ts}
        }

        test {Establish bidirectional active-replica topology} {
            $node0 replicaof add $node1_host $node1_port
            wait_for_condition 150 100 {
                [s -1 master_link_status] eq {up} &&
                [s 0 master_link_status] eq {up}
            } else {
                fail "Bidirectional active-replica links not established"
            }
            # Persist configuration of upstreams to RDB so they are restored on restart
            $node0 save
            $node1 save
        }

        test {LWW convergence after network partition and recovery (Case A: Node 0 writes newer)} {
            # Clear keys
            $node0 del mm:partition
            wait_for_condition 100 100 {
                [$node1 get mm:partition] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Save Node 1 state and shut down Node 0 to simulate partition.
            $node1 save
            catch {$node0 shutdown nosave}

            # 2. Write older value on Node 1
            $node1 set mm:partition val_node1

            # 3. Save Node 1 state with pending frame queue
            $node1 save

            # 4. Start Node 0, but immediately shut down Node 1 to keep them partitioned.
            restart_server -1 true false
            set node0 [srv -1 client]
            catch {$node1 shutdown nosave}

            # 5. Write newer value on Node 0 (wait a bit so physical clock changes)
            after 100
            $node0 set mm:partition val_node0

            # 6. Save Node 0 state
            $node0 save

            # 7. Restart Node 1 to heal the partition
            restart_server 0 true false
            set node1 [srv 0 client]

            # 8. Wait for reconnection
            wait_for_condition 150 100 {
                [s -1 master_link_status] eq {up} &&
                [s 0 master_link_status] eq {up}
            } else {
                fail "Bidirectional links did not recover"
            }

            # 9. Verify convergence to val_node0 (Node 0's write has a higher timestamp)
            wait_for_condition 100 100 {
                [$node0 get mm:partition] eq {val_node0} &&
                [$node1 get mm:partition] eq {val_node0}
            } else {
                fail "LWW partition recovery Case A failed: node0=[$node0 get mm:partition] node1=[$node1 get mm:partition]"
            }
        }

        test {LWW convergence after network partition and recovery (Case B: Node 1 writes newer)} {
            # Clear keys
            $node0 del mm:partition
            wait_for_condition 100 100 {
                [$node1 get mm:partition] eq {}
            } else {
                fail "Clean delete did not propagate"
            }

            # 1. Save Node 0 state and shut down Node 1 to simulate partition.
            $node0 save
            catch {$node1 shutdown nosave}

            # 2. Write older value on Node 0
            $node0 set mm:partition val_node0

            # 3. Save Node 0 state with pending frame queue
            $node0 save

            # 4. Start Node 1, but immediately shut down Node 0 to keep them partitioned.
            restart_server 0 true false
            set node1 [srv 0 client]
            catch {$node0 shutdown nosave}

            # 5. Write newer value on Node 1 (wait a bit so physical clock changes)
            after 100
            $node1 set mm:partition val_node1

            # 6. Save Node 1 state
            $node1 save

            # 7. Restart Node 0 to heal the partition
            restart_server -1 true false
            set node0 [srv -1 client]

            # 8. Wait for reconnection
            wait_for_condition 150 100 {
                [s -1 master_link_status] eq {up} &&
                [s 0 master_link_status] eq {up}
            } else {
                fail "Bidirectional links did not recover"
            }

            # 9. Verify convergence to val_node1 (Node 1's write has a higher timestamp)
            wait_for_condition 100 100 {
                [$node0 get mm:partition] eq {val_node1} &&
                [$node1 get mm:partition] eq {val_node1}
            } else {
                fail "LWW partition recovery Case B failed: node0=[$node0 get mm:partition] node1=[$node1 get mm:partition]"
            }
        }
    }
}
