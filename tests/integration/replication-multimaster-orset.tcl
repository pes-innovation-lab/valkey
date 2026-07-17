# Active-active multi-master replication with Observed-Remove Set (OR-Set)

start_server {tags {"repl external:skip"}} {
    start_server {overrides {save {}}} {
        set node0 [srv -1 client]
        set node0_host [srv -1 host]
        set node0_port [srv -1 port]
        set node0_pid [srv -1 pid]
        
        set node1 [srv 0 client]
        set node1_host [srv 0 host]
        set node1_port [srv 0 port]
        set node1_pid [srv 0 pid]

        test {Establish active-active multi-master link for OR-Set} {
            # Clear keys before enabling multi-master mode
            $node0 del mm:set
            $node1 del mm:set

            foreach n [list $node0 $node1] {
                $n config set active-replica yes
                $n config set multi-master yes
                $n config set replica-read-only no
                $n config set multi-master-whitelist "sadd srem"
            }

            $node0 multimaster add $node1_host $node1_port
            $node1 multimaster add $node0_host $node0_port

            wait_for_condition 100 100 {
                [s -1 active_upstream_runtime_links] >= 1 &&
                [s 0 active_upstream_runtime_links] >= 1
            } else {
                fail "Replica links not established"
            }
        }

        test {Basic SADD and SREM replicate} {
            $node0 sadd mm:set member1
            wait_for_condition 100 100 {
                [$node1 sismember mm:set member1] == 1
            } else {
                fail "SADD did not replicate to node1"
            }

            $node0 srem mm:set member1
            wait_for_condition 100 100 {
                [$node1 sismember mm:set member1] == 0
            } else {
                fail "SREM did not replicate to node1"
            }
        }

        test {Concurrent SADD and SREM (Observed-Remove behaviour)} {
            # Clean up: temporarily disable whitelist to allow DEL
            foreach n [list $node0 $node1] {
                $n config set multi-master-whitelist ""
            }
            $node0 del mm:set
            $node1 del mm:set
            foreach n [list $node0 $node1] {
                $n config set multi-master-whitelist "sadd srem"
            }

            # 1. Node 0 adds member1. This replicates to Node 1.
            $node0 sadd mm:set member1
            wait_for_condition 100 100 {
                [$node1 sismember mm:set member1] == 1
            } else {
                fail "Initial add did not replicate"
            }

            # 2. Simulate concurrent operations under partition.
            # We pause Node 1, perform SREM on Node 0 (queues RREPLAY SREM).
            pause_process $node1_pid

            $node0 srem mm:set member1

            # We resume Node 1, pause Node 0, and perform SADD on Node 1 (queues RREPLAY SADD).
            resume_process $node1_pid
            pause_process $node0_pid

            $node1 sadd mm:set member1

            # Resume Node 0 to heal the partition and let the queues flush.
            resume_process $node0_pid

            # 3. Wait for convergence and assert member1 is present on both nodes.
            # Due to Observed-Remove semantics, Node 1's concurrent SADD has a tag
            # that Node 0's SREM did not observe, so the member must survive.
            wait_for_condition 150 100 {
                [$node0 sismember mm:set member1] == 1 &&
                [$node1 sismember mm:set member1] == 1
            } else {
                fail "Observed-Remove convergence failed: node0=[$node0 sismember mm:set member1] node1=[$node1 sismember mm:set member1]"
            }
        }
    }
}
