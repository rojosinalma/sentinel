# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @saved = ENV.to_h.slice("NODE_NAME", "CLUSTER_FILE", "POLL_INTERVAL_S", "AUTO_PROMOTE")
    Sentinel::Config.reset!
  end

  def teardown
    %w[NODE_NAME CLUSTER_FILE POLL_INTERVAL_S AUTO_PROMOTE].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    Sentinel::Config.reset!
  end

  def test_defaults_and_types
    assert_equal 2, Sentinel::Config.fetch(:POLL_INTERVAL_S)
    assert_equal "on", Sentinel::Config.fetch(:AUTO_PROMOTE)
    assert_equal 30, Sentinel::Config.fetch(:LEASE_TTL_S)
  end

  def test_env_override_and_cast
    ENV["POLL_INTERVAL_S"] = "5"
    assert_equal 5, Sentinel::Config.fetch(:POLL_INTERVAL_S)
  end

  def test_bad_cast_falls_back
    ENV["POLL_INTERVAL_S"] = "fast"
    assert_equal 2, Sentinel::Config.fetch(:POLL_INTERVAL_S)
  end

  def test_unknown_key_raises
    assert_raises(KeyError) { Sentinel::Config.fetch(:NOPE) }
  end

  def test_node_name_required
    ENV.delete("NODE_NAME")
    assert_raises(Sentinel::Config::Error) { Sentinel::Config.node_name }
  end

  def test_cluster
    with_cluster_file do
      ENV["NODE_NAME"] = "tiny"
      Sentinel::Config.reset!
      cluster = Sentinel::Config.cluster

      assert_equal %w[silver tiny witness-1], cluster.hosts.keys
      assert_equal 2, cluster.majority
      assert_equal %w[silver witness-1], cluster.peers.map(&:name)
      assert_equal :witness, cluster.host("witness-1").role
      assert cluster.host("witness-1").witness?
      assert_equal 22, cluster.host("silver").probes[:ssh]
      assert_nil cluster.host("witness-1").probes[:traefik]

      svc = cluster.service("opencode")
      assert_equal "silver", svc.primary
      assert_equal "tiny", svc.standby
      assert_equal "http://10.0.0.1:4096/api/info", svc.health["silver"]
      assert Sentinel::Config.acting_node?("opencode")

      assert_equal ["10.0.0.3:53"], cluster.quorum_tcp
      assert_raises(Sentinel::Config::Error) { cluster.host("nope") }
    end
  end

  def test_unknown_node_rejected
    with_cluster_file do
      ENV["NODE_NAME"] = "mars"
      Sentinel::Config.reset!
      assert_raises(Sentinel::Config::Error) { Sentinel::Config.cluster }
    end
  end

  private

  CLUSTER_YML = <<~YAML
    hosts:
      silver:   {address: 10.0.0.1, sentinel_url: http://10.0.0.1:4197, role: member, probes: {ssh: 22, traefik: 443, icmp: true}}
      tiny:     {address: 10.0.0.2, sentinel_url: http://10.0.0.2:4197, role: member, probes: {ssh: 22, traefik: 443, icmp: true}}
      witness-1: {address: 10.0.0.5, sentinel_url: http://10.0.0.5:4197, role: witness, probes: {ssh: 22, icmp: true}}
    quorum_tcp: [10.0.0.3:53]
    services:
      opencode:
        primary: silver
        standby: tiny
        health: {silver: "http://10.0.0.1:4096/api/info", tiny: "http://10.0.0.2:4096/api/info"}
        hooks_dir: hooks/opencode
  YAML

  def with_cluster_file
    dir = tmp_state_dir
    file = File.join(dir, "cluster.yml")
    File.write(file, CLUSTER_YML)
    ENV["CLUSTER_FILE"] = file
    yield
  end
end
