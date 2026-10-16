# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Shared scaffolding for the gossip/lease tests: a 3-node cluster wired by InProcess transport.
module ClusterHarness
  CLUSTER_YML = <<~YAML
    hosts:
      node-a:   {address: 127.0.0.1, sentinel_url: http://node-a:4197, role: member, probes: {ssh: 22}}
      node-b:     {address: 127.0.0.2, sentinel_url: http://node-b:4197, role: member, probes: {ssh: 22}}
      witness-1: {address: 127.0.0.3, sentinel_url: http://witness-1:4197, role: witness, probes: {ssh: 22}}
    quorum_tcp: []
    services:
      opencode:
        primary: node-a
        standby: node-b
        health: {}
        hooks_dir: hooks/opencode
  YAML

  def cluster_for(node)
    Sentinel::Config::Cluster.new(YAML.safe_load(CLUSTER_YML), node_name: node)
  end

  def view_body(node, at:, hosts: {}, primary: {}, primary_at: {}, seq: 1)
    JSON.generate(
      "node" => node, "at" => at, "seq" => seq, "primary" => primary, "primary_at" => primary_at,
      "hosts" => hosts, "quorum" => "up", "reachable_peers" => [], "hold" => false,
      "transition" => nil, "lease" => nil
    )
  end

  def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
end

class GossipTest < Minitest::Test
  include ClusterHarness

  def setup
    @clock = FakeClock.new
    @store = memory_store
  end

  def gossip(apps, node: "node-b", stale_s: 10)
    Sentinel::Gossip.new(cluster: cluster_for(node), transport: Sentinel::Transport::InProcess.new(apps),
                         store: @store, stale_s: stale_s, now: @clock.to_proc)
  end

  def test_poll_stores_fresh_views_and_reachability
    peer_body = view_body("node-a", at: iso(@clock.now))
    apps = {
      "http://node-a:4197" => ->(_m, _p, _b) { [200, peer_body] },
      "http://witness-1:4197" => ->(_m, _p, _b) { raise "down" }
    }
    g = gossip(apps)
    g.poll!
    assert_equal %w[node-a], g.views.keys
    assert_equal %w[node-a], g.reachable_peers
    assert g.quorum?, "1 reachable peer + self = 2 >= majority 2"
  end

  def test_no_quorum_when_alone
    apps = {
      "http://node-a:4197" => ->(*) { raise "down" },
      "http://witness-1:4197" => ->(*) { raise "down" }
    }
    g = gossip(apps)
    g.poll!
    assert_empty g.reachable_peers
    refute g.quorum?
  end

  def test_mismatched_node_dropped
    apps = { "http://node-a:4197" => ->(*) { [200, view_body("impostor", at: iso(@clock.now))] },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    g.poll!
    assert_empty g.views
    refute g.quorum?
  end

  def test_stale_views_lose_their_vote
    apps = { "http://node-a:4197" => ->(*) { [200, view_body("node-a", at: iso(@clock.now))] },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    g.poll!
    assert g.quorum?
    @clock.advance(60)
    assert_empty g.views, "view older than stale_s is gone"
    refute g.quorum?
  end

  def test_agreement
    hosts = { "node-a" => { "classes" => { "opencode" => "dead" } } }
    apps = { "http://node-a:4197" => ->(*) { raise "down" },
             "http://witness-1:4197" => ->(*) { [200, view_body("witness-1", at: iso(@clock.now), hosts: hosts)] } }
    g = gossip(apps)
    g.poll!
    assert_equal({ "node-b" => :dead, "witness-1" => :dead }, g.classes_for("opencode", "node-a", :dead))
    assert_equal :dead, g.agreed_class("opencode", "node-a", :dead)
    assert_equal :ok, g.agreed_class("opencode", "node-a", :ok), "1 dead vote of 2 present is no dead majority"
  end

  def test_agreement_is_per_service
    hosts = { "node-a" => { "classes" => { "opencode" => "dead", "other" => "ok" } } }
    apps = { "http://node-a:4197" => ->(*) { raise "down" },
             "http://witness-1:4197" => ->(*) { [200, view_body("witness-1", at: iso(@clock.now), hosts: hosts)] } }
    g = gossip(apps)
    g.poll!
    assert_equal :dead, g.agreed_class("opencode", "node-a", :dead)
    assert_equal :ok, g.agreed_class("other", "node-a", :dead), "the peer's vote on 'other' is ok"
    assert_equal({ "node-b" => :dead }, g.classes_for("unknown", "node-a", :dead), "no peer vote on an unknown service")
  end

  def test_agreement_disagreeing_peer
    hosts = { "node-a" => { "classes" => { "opencode" => "ok" } } }
    apps = { "http://node-a:4197" => ->(*) { raise "down" },
             "http://witness-1:4197" => ->(*) { [200, view_body("witness-1", at: iso(@clock.now), hosts: hosts)] } }
    g = gossip(apps)
    g.poll!
    assert_equal :ok, g.agreed_class("opencode", "node-a", :dead), "1 dead vote of 2 present is no majority"
  end

  def test_primary_newest_wins
    old = iso(@clock.now - 3600)
    new = iso(@clock.now - 60)
    apps = { "http://node-a:4197" => lambda { |*|
               [200, view_body("node-a", at: iso(@clock.now),
                               primary: { "opencode" => "node-a" }, primary_at: { "opencode" => old })]
             },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    assert_nil g.primary("opencode")
    g.poll!
    assert_equal "node-a", g.primary("opencode")
    @store.set("primary.opencode", "node-b")
    @store.set("primary_at.opencode", new)
    assert_equal "node-b", g.primary("opencode"), "newer local value wins"
  end

  # primary_state carries the winning view's per-service transition; the local store has none,
  # and a pre-0.5.6 view without "transitions" reads as nil.
  def test_primary_state_carries_the_acting_nodes_transition
    at = iso(@clock.now - 60)
    body = JSON.parse(view_body("node-a", at: iso(@clock.now), primary: { "opencode" => "node-b", "other" => "node-a" },
                                primary_at: { "opencode" => at, "other" => at }))
    body["transitions"] = { "opencode" => "promote 20260101T115900Z", "other" => nil }
    apps = { "http://node-a:4197" => ->(*) { [200, JSON.generate(body)] }, "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    assert_nil g.primary_state("opencode")
    g.poll!
    ps = g.primary_state("opencode")
    assert_equal "node-b", ps[:host]
    assert_equal Time.iso8601(at), ps[:at]
    assert_equal "promote 20260101T115900Z", ps[:transition]
    assert_nil g.primary_state("other")[:transition]

    @store.set("primary.opencode", "node-a")
    @store.set("primary_at.opencode", iso(@clock.now - 10))
    assert_equal({ host: "node-a", at: @clock.now - 10, transition: nil }, g.primary_state("opencode"),
                 "newer local row wins and carries no transition")

    body.delete("transitions")
    g.poll!
    @store.set("primary_at.opencode", iso(@clock.now - 3600))
    assert_nil g.primary_state("opencode")[:transition], "old view schema: no per-service transition"
  end

  def test_local_view_shape_and_seq
    g = gossip({ "http://node-a:4197" => ->(*) { raise "x" }, "http://witness-1:4197" => ->(*) { raise "x" } })
    hosts = { "node-a" => Sentinel::HostView.new(name: "node-a", services: { "opencode" => "down", "other" => "up 1" },
                                                 ssh: "up", icmp: "up", https: "up", probed_at: @clock.now),
              "witness-1" => Sentinel::HostView.new(name: "witness-1", ssh: "up", probed_at: @clock.now) }
    classes = { "opencode" => { "node-a" => :degraded, "witness-1" => :ok }, "other" => { "node-a" => :ok } }
    2.times do |i|
      body = g.local_view(hosts: hosts, classes: classes,
                          primary: { "opencode" => "node-a" },
                          primary_at: { "opencode" => iso(@clock.now) },
                          hold: false, transition: "promote 20260101T120000Z", quorum: "up",
                          transitions: { "opencode" => "promote 20260101T120000Z", "other" => nil })
      assert_equal "node-b", body["node"]
      assert_equal "promote 20260101T120000Z", body["transition"], "node-wide key kept for older readers"
      assert_equal({ "opencode" => "promote 20260101T120000Z", "other" => nil }, body["transitions"])
      assert_equal i + 1, body["seq"]
      assert_equal({ "opencode" => "degraded", "other" => "ok" }, body.dig("hosts", "node-a", "classes"))
      assert_equal({ "opencode" => "ok" }, body.dig("hosts", "witness-1", "classes"), "no entry for a service without a vote")
      assert_equal({ "opencode" => "down", "other" => "up 1" }, body.dig("hosts", "node-a", "services"))
      assert_equal "up", body.dig("hosts", "node-a", "ssh")
      refute body.dig("hosts", "node-a").key?("name")
      refute body.dig("hosts", "node-a").key?("class"), "schema v2 has no single class"
      assert body.key?("lease")
      assert_equal "2026-01-01T12:00:00Z", body["at"]
    end
  end
end
