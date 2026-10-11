# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Shared scaffolding for the gossip/lease tests: a 3-node cluster wired by InProcess transport.
module ClusterHarness
  CLUSTER_YML = <<~YAML
    hosts:
      silver:   {address: 127.0.0.1, sentinel_url: http://silver:4197, role: member, probes: {ssh: 22}}
      tiny:     {address: 127.0.0.2, sentinel_url: http://tiny:4197, role: member, probes: {ssh: 22}}
      witness-1: {address: 127.0.0.3, sentinel_url: http://witness-1:4197, role: witness, probes: {ssh: 22}}
    quorum_tcp: []
    services:
      opencode:
        primary: silver
        standby: tiny
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

  def gossip(apps, node: "tiny", stale_s: 10)
    Sentinel::Gossip.new(cluster: cluster_for(node), transport: Sentinel::Transport::InProcess.new(apps),
                         store: @store, stale_s: stale_s, now: @clock.to_proc)
  end

  def test_poll_stores_fresh_views_and_reachability
    silver_body = view_body("silver", at: iso(@clock.now))
    apps = {
      "http://silver:4197" => ->(_m, _p, _b) { [200, silver_body] },
      "http://witness-1:4197" => ->(_m, _p, _b) { raise "down" }
    }
    g = gossip(apps)
    g.poll!
    assert_equal %w[silver], g.views.keys
    assert_equal %w[silver], g.reachable_peers
    assert g.quorum?, "1 reachable peer + self = 2 >= majority 2"
  end

  def test_no_quorum_when_alone
    apps = {
      "http://silver:4197" => ->(*) { raise "down" },
      "http://witness-1:4197" => ->(*) { raise "down" }
    }
    g = gossip(apps)
    g.poll!
    assert_empty g.reachable_peers
    refute g.quorum?
  end

  def test_mismatched_node_dropped
    apps = { "http://silver:4197" => ->(*) { [200, view_body("impostor", at: iso(@clock.now))] },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    g.poll!
    assert_empty g.views
    refute g.quorum?
  end

  def test_stale_views_lose_their_vote
    apps = { "http://silver:4197" => ->(*) { [200, view_body("silver", at: iso(@clock.now))] },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    g.poll!
    assert g.quorum?
    @clock.advance(60)
    assert_empty g.views, "view older than stale_s is gone"
    refute g.quorum?
  end

  def test_agreement
    hosts = { "silver" => { "class" => "dead" } }
    apps = { "http://silver:4197" => ->(*) { raise "down" },
             "http://witness-1:4197" => ->(*) { [200, view_body("witness-1", at: iso(@clock.now), hosts: hosts)] } }
    g = gossip(apps)
    g.poll!
    assert_equal({ "tiny" => :dead, "witness-1" => :dead }, g.classes_for("silver", :dead))
    assert_equal :dead, g.agreed_class("silver", :dead)
    assert_equal :ok, g.agreed_class("silver", :ok), "1 dead vote of 2 present is no dead majority"
  end

  def test_agreement_disagreeing_peer
    hosts = { "silver" => { "class" => "ok" } }
    apps = { "http://silver:4197" => ->(*) { raise "down" },
             "http://witness-1:4197" => ->(*) { [200, view_body("witness-1", at: iso(@clock.now), hosts: hosts)] } }
    g = gossip(apps)
    g.poll!
    assert_equal :ok, g.agreed_class("silver", :dead), "1 dead vote of 2 present is no majority"
  end

  def test_primary_newest_wins
    old = iso(@clock.now - 3600)
    new = iso(@clock.now - 60)
    apps = { "http://silver:4197" => lambda { |*|
               [200, view_body("silver", at: iso(@clock.now),
                               primary: { "opencode" => "silver" }, primary_at: { "opencode" => old })]
             },
             "http://witness-1:4197" => ->(*) { raise "down" } }
    g = gossip(apps)
    assert_nil g.primary("opencode")
    g.poll!
    assert_equal "silver", g.primary("opencode")
    @store.set("primary.opencode", "tiny")
    @store.set("primary_at.opencode", new)
    assert_equal "tiny", g.primary("opencode"), "newer local value wins"
  end

  def test_local_view_shape_and_seq
    g = gossip({ "http://silver:4197" => ->(*) { raise "x" }, "http://witness-1:4197" => ->(*) { raise "x" } })
    hosts = { "silver" => Sentinel::HostView.new(name: "silver", opencode: "down", ssh: "up",
                                                 icmp: "up", traefik: "up", probed_at: @clock.now) }
    2.times do |i|
      body = g.local_view(hosts: hosts, classes: { "silver" => :degraded },
                          primary: { "opencode" => "silver" },
                          primary_at: { "opencode" => iso(@clock.now) },
                          hold: false, transition: nil, quorum: "up")
      assert_equal "tiny", body["node"]
      assert_equal i + 1, body["seq"]
      assert_equal "degraded", body.dig("hosts", "silver", "class")
      assert_equal "up", body.dig("hosts", "silver", "ssh")
      refute body.dig("hosts", "silver").key?("name")
      assert body.key?("lease")
      assert_equal "2026-01-01T12:00:00Z", body["at"]
    end
  end
end
