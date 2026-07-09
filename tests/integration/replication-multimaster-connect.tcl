start_server {tags {"multi-master external:skip"} overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
start_server {overrides {save {} active-replica yes multi-master yes replica-read-only no}} {
    set replica [srv -3 client]
    set p1 [srv -2 client]
    set p1_host [srv -2 host]
    set p1_port [srv -2 port]
    set p2 [srv -1 client]
    set p2_host [srv -1 host]
    set p2_port [srv -1 port]
    set p3 [srv 0 client]
    set p3_host [srv 0 host]
    set p3_port [srv 0 port]

    test {Connect to first upstream and replicate} {
        $replica multimaster add $p1_host $p1_port
        wait_for_condition 100 100 {
            [s -3 active_upstream_runtime_links] >= 1
        } else {
            fail "replica did not connect to upstream #1"
        }

        $p1 set mmc:key1 v1
        wait_for_condition 100 100 {
            [$replica get mmc:key1] eq {v1}
        } else {
            fail "replica did not receive data from upstream #1"
        }
    }

    test {Connect to additional upstreams} {
        $replica multimaster add $p2_host $p2_port
        $replica multimaster add $p3_host $p3_port
        assert_equal 3 [s -3 configured_upstreams]
    }

    # skipping this test as it uses old master replica connection (from replicaof add)
    if {0} {
    test {Per-peer PSYNC reconnect failover stress in concurrent mode} {
        set observed_ports {}
        for {set i 0} {$i < 18} {incr i} {
            catch {$replica client kill type master}
            wait_for_condition 150 100 {
                [s -3 active_upstream_runtime_links] >= 1
            } else {
                fail "replica did not reconnect during failover stress loop #$i"
            }

            set active_port ""
            for {set j 0} {$j < 3} {incr j} {
                catch {
                    set m_info [s -3 master_$j]
                    if {[string match "*state=online*" $m_info]} {
                        regexp {port=(\d+)} $m_info match active_port
                        break
                    }
                }
            }
            if {$active_port eq ""} {
                fail "no active upstream found in info replication"
            }
            lappend observed_ports $active_port

            set writer ""
            if {$active_port == $p1_port} {
                set writer $p1
            } elseif {$active_port == $p2_port} {
                set writer $p2
            } elseif {$active_port == $p3_port} {
                set writer $p3
            } else {
                fail "unexpected active upstream port $active_port"
            }

            set k "mmc:stress:$i"
            set v "v$i"
            $writer set $k $v
            wait_for_condition 100 100 {
                [$replica get $k] eq $v
            } else {
                fail "replica did not apply stress key $k from upstream port $active_port"
            }
        }

        set uniq_ports [lsort -unique $observed_ports]
        assert {[llength $uniq_ports] >= 2}
    }
    }

    # skipping both these tests as they were used for the original replicaof psync connections, which are removed now
    if {0} {
    test {Switch to second upstream and replicate} {
        $replica multimaster remove
        wait_for_condition 150 100 {
            [s -3 active_upstream_runtime_links] >= 1
        } else {
            fail "replica did not fail over to upstream #2"
        }

        $p2 set mmc:key2 v2
        wait_for_condition 100 100 {
            [$replica get mmc:key2] eq {v2}
        } else {
            fail "replica did not receive data from upstream #2"
        }
    }
    }

    if {0} {

    test {Switch to third upstream and replicate} {
        $replica multimaster remove
        wait_for_condition 150 100 {
            [s -3 active_upstream_runtime_links] >= 1
        } else {
            fail "replica did not fail over to upstream #3"
        }

        $p3 set mmc:key3 v3
        wait_for_condition 100 100 {
            [$replica get mmc:key3] eq {v3}
        } else {
            fail "replica did not receive data from upstream #3"
        }
    }
    }
}}}}
