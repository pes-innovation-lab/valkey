start_server {tags {"multi-master external:skip"} overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {

    set R(0) [srv 0 client]
    set R(1) [srv -1 client]
    set RH(0) [srv 0 host]
    set RP(0) [srv 0 port]
    set RH(1) [srv -1 host]
    set RP(1) [srv -1 port]

    test "Multimaster Add creates two-way replication" {
        $R(1) multimaster add $RH(0) $RP(0)
        
        wait_for_condition 150 100 {
            [s -1 active_upstream_runtime_links] >= 1 &&
            [s 0 active_upstream_runtime_links] >= 1
        } else {
            fail "connection not established"
        }
    }

    test "Replication works from Node 0 to Node 1" {
        $R(0) set node0_key "data_from_0"
        
        wait_for_condition 50 100 {
            [$R(1) get node0_key] eq "data_from_0"
        } else {
            fail "Replication failed from Node 0 to Node 1"
        }
    }

    test "Replication works from Node 1 to Node 0 (Active-Active)" {
        $R(1) set node1_key "data_from_1"
        
        wait_for_condition 50 100 {
            [$R(0) get node1_key] eq "data_from_1"
        } else {
            fail "Replication failed from Node 1 to Node 0"
        }
    }

    test "Multimaster Remove cascades and stops replication" {
        # Running it with just 'remove' triggers the 2-argument cascade delete
        $R(1) multimaster remove

        wait_for_condition 150 100 {
            [s -1 active_upstream_runtime_links] == 0 &&
            [s 0 active_upstream_runtime_links] == 0
        } else {
            fail "disconnection failed"
        }

        # Now test that replication is dead
        $R(0) set post_remove_0 "isolated_0"
        $R(1) set post_remove_1 "isolated_1"
        
        # Give it a second to fail to replicate
        after 1000
        
        assert_equal {} [$R(1) get post_remove_0]
        assert_equal {} [$R(0) get post_remove_1]
    }
}
}
