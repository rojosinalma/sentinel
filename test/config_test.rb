# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

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
      ENV["NODE_NAME"] = "node-b"
      Sentinel::Config.reset!
      cluster = Sentinel::Config.cluster

      assert_equal %w[node-a node-b witness-1], cluster.hosts.keys
      assert_equal 2, cluster.majority
      assert_equal %w[node-a witness-1], cluster.peers.map(&:name)
      assert_equal :witness, cluster.host("witness-1").role
      assert cluster.host("witness-1").witness?
      assert_equal 22, cluster.host("node-a").probes[:ssh]
      assert_nil cluster.host("witness-1").probes[:traefik]

      svc = cluster.service("opencode")
      assert_equal "node-a", svc.primary
      assert_equal "node-b", svc.standby
      assert_equal "http://10.0.0.1:4096/api/info", svc.health["node-a"]
      assert Sentinel::Config.acting_node?("opencode")

      assert_equal ["10.0.0.3:53"], cluster.quorum_tcp
      assert_raises(Sentinel::Config::Error) { cluster.host("nope") }
    end
  end

  def test_service_probe_auto_promote_and_tunables
    with_cluster_file(CLUSTER_YML + SECOND_SERVICE_YML) do
      ENV["NODE_NAME"] = "node-b"
      ENV["BEACON_USER"] = "beacon"
      ENV["BEACON_PASS"] = "s3cret"
      Sentinel::Config.reset!
      cluster = Sentinel::Config.cluster

      plain = cluster.service("opencode")
      assert_nil plain.probe.basic
      assert_equal({}, plain.probe.headers)
      assert_nil plain.probe.resolve_ip("node-a")
      assert_nil plain.auto_promote
      assert_equal({}, plain.tunables)

      beacon = cluster.service("beacon")
      assert_equal %w[beacon s3cret], beacon.probe.basic
      assert_equal({ "X-Probe" => "sentinel" }, beacon.probe.headers)
      assert_equal "10.0.0.1", beacon.probe.resolve_ip("node-a")
      assert_equal "10.0.0.2", beacon.probe.resolve_ip("node-b")
      assert_equal false, beacon.auto_promote
      assert_equal({ promote_after_s: 90, dead_confirm_polls: 3 }, beacon.tunables)
      assert_equal "hooks/beacon", beacon.hooks_dir
    end
  ensure
    ENV.delete("BEACON_USER")
    ENV.delete("BEACON_PASS")
  end

  def test_decider_config_applies_service_overrides
    with_cluster_file(CLUSTER_YML + SECOND_SERVICE_YML) do
      ENV["NODE_NAME"] = "node-b"
      Sentinel::Config.reset!
      cluster = Sentinel::Config.cluster
      node = { auto_promote: "on", promote_after_s: 60, dead_confirm_polls: 5, failback_after_s: 30 }.freeze

      plain = Sentinel.decider_config(node, cluster.service("opencode"))
      assert_equal "on", plain[:auto_promote]
      assert_equal 60, plain[:promote_after_s]

      beacon = Sentinel.decider_config(node, cluster.service("beacon"))
      assert_equal "off", beacon[:auto_promote]
      assert_equal 90, beacon[:promote_after_s]
      assert_equal 3, beacon[:dead_confirm_polls]
      assert_equal 30, beacon[:failback_after_s], "untouched tunables stay node-wide"
      assert_equal "beacon-node-b", beacon[:label]
    end
  end

  def test_probe_username_literal_fallback_and_empty_password
    yml = CLUSTER_YML.sub("hooks_dir: hooks/opencode", "probe: {username: opencode, username_env: NOPE_USER, password_env: NOPE_PASS}")
    with_cluster_file(yml) do
      ENV["NODE_NAME"] = "node-b"
      Sentinel::Config.reset!
      assert_nil Sentinel::Config.cluster.service("opencode").probe.basic, "no password -> no credential"
      ENV["NOPE_PASS"] = "pw"
      Sentinel::Config.reset!
      assert_equal %w[opencode pw], Sentinel::Config.cluster.service("opencode").probe.basic
    end
  ensure
    ENV.delete("NOPE_PASS")
  end

  def test_unknown_tunable_rejected
    yml = CLUSTER_YML.sub("hooks_dir: hooks/opencode", "tunables: {poll_interval_s: 1}")
    with_cluster_file(yml) do
      ENV["NODE_NAME"] = "node-b"
      Sentinel::Config.reset!
      err = assert_raises(Sentinel::Config::Error) { Sentinel::Config.cluster }
      assert_match(/unknown tunable/, err.message)
    end
  end

  def test_node_name_error_lists_cluster_hosts
    with_cluster_file do
      ENV.delete("NODE_NAME")
      err = assert_raises(Sentinel::Config::Error) { Sentinel::Config.node_name }
      assert_match(/node-a \| node-b \| witness-1/, err.message)
    end
  end

  def test_unknown_node_rejected
    with_cluster_file do
      ENV["NODE_NAME"] = "mars"
      Sentinel::Config.reset!
      assert_raises(Sentinel::Config::Error) { Sentinel::Config.cluster }
    end
  end

  def test_service_routes_default_to_ha_routes_group_named_after_the_service
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(CLUSTER_YML), node_name: "node-b")
    routes = cluster.service("opencode").routes
    assert_equal "ha-routes", routes.mode
    assert_equal "opencode", routes.group
    assert_empty routes.pihole_names
    assert routes.ha_routes?
    assert routes.frozen?
  end

  def test_service_routes_parsed
    doc = YAML.safe_load(CLUSTER_YML)
    doc["services"]["beacon"] = {
      "primary" => "node-a", "standby" => "node-b", "health" => {},
      "routes" => { "mode" => "pihole", "pihole_names" => ["beacon.example.com", "mqtt.example.com"] }
    }
    doc["services"]["grouped"] = {
      "primary" => "node-a", "standby" => "node-b", "health" => {},
      "routes" => { "group" => "ha-foo" }
    }
    cluster = Sentinel::Config::Cluster.new(doc, node_name: "node-b")
    beacon = cluster.service("beacon").routes
    assert_equal "pihole", beacon.mode
    assert_equal "beacon", beacon.group
    assert_equal %w[beacon.example.com mqtt.example.com], beacon.pihole_names
    refute beacon.ha_routes?
    assert_equal ["ha-routes", "ha-foo"], cluster.service("grouped").routes.then { |r| [r.mode, r.group] }
  end

  def test_service_routes_bad_mode_rejected
    doc = YAML.safe_load(CLUSTER_YML)
    doc["services"]["opencode"]["routes"] = { "mode" => "dns" }
    err = assert_raises(Sentinel::Config::Error) { Sentinel::Config::Cluster.new(doc, node_name: "node-b") }
    assert_match(/routes.mode "dns"/, err.message)
  end

  def test_service_urls
    yml = <<~YAML
      hosts:
        node-a: {address: 10.0.0.1, sentinel_url: http://node-a:4197, role: member, probes: {}}
        node-b:   {address: 10.0.0.2, sentinel_url: http://node-b:4197, role: member, probes: {}}
      services:
        app:
          primary: node-a
          standby: node-b
          health: {node-a: "http://10.0.0.1:4096/api/info", node-b: "https://app-node-b.node-b.example.com/health"}
          url: https://app.example.com
          host_urls: {node-a: https://app.node-a.example.com}
    YAML
    svc = Sentinel::Config::Cluster.new(YAML.safe_load(yml), node_name: "node-a").services["app"]
    assert_equal "https://app.example.com", svc.url
    assert_equal({ "node-a" => "https://app.node-a.example.com", "node-b" => "https://app-node-b.node-b.example.com" }, svc.host_urls)
  end

  private

  CLUSTER_YML = <<~YAML
    hosts:
      node-a:   {address: 10.0.0.1, sentinel_url: http://10.0.0.1:4197, role: member, probes: {ssh: 22, traefik: 443, icmp: true}}
      node-b:     {address: 10.0.0.2, sentinel_url: http://10.0.0.2:4197, role: member, probes: {ssh: 22, traefik: 443, icmp: true}}
      witness-1: {address: 10.0.0.5, sentinel_url: http://10.0.0.5:4197, role: witness, probes: {ssh: 22, icmp: true}}
    quorum_tcp: [10.0.0.3:53]
    services:
      opencode:
        primary: node-a
        standby: node-b
        health: {node-a: "http://10.0.0.1:4096/api/info", node-b: "http://10.0.0.2:4096/api/info"}
        hooks_dir: hooks/opencode
  YAML

  SECOND_SERVICE_YML = <<~YAML.gsub(/^/, "  ")
    beacon:
      primary: node-a
      standby: node-b
      health: {node-a: "https://beacon.example/health", node-b: "https://beacon.example/health"}
      probe:
        username_env: BEACON_USER
        password_env: BEACON_PASS
        headers: {X-Probe: sentinel}
        resolve: {node-a: 10.0.0.1, node-b: 10.0.0.2}
      auto_promote: false
      tunables: {promote_after_s: 90, dead_confirm_polls: 3}
  YAML

  def with_cluster_file(content = CLUSTER_YML)
    dir = tmp_state_dir
    file = File.join(dir, "cluster.yml")
    File.write(file, content)
    ENV["CLUSTER_FILE"] = file
    yield
  end

end
