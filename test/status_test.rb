# frozen_string_literal: true

require_relative "test_helper"
require_relative "loop_test"
require "json"
require "yaml"

class StatusTest < Minitest::Test
  # The bash sentinel's exact key order (live /status, 2026-10-11). Byte compatibility.
  BASH_KEYS = %w[
    mode since primary_service primary_service_version primary_host primary_host_health quorum
    classification dead_polls host_probes poll_interval_s dead_confirm_polls promoting transition
    auto_promote auto_failback hold down_since promote_after_s promote_cooldown_left_s
    promote_retry_left_s primary_stable_since failback_after_s failback_retry_left_s
    flips_in_window standby_stack route_mode route_primary ha_connectors checked_at status_age_s
  ].freeze

  def setup
    @h = build_harness
  end

  def build_harness
    clock = FakeClock.new
    state = Sentinel::State.new(tmp_state_dir)
    store = Sentinel::Store.memory(node: "node-b")
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(LoopTest::CLUSTER_YML), node_name: "node-b")
    config = LoopTest::CONFIG.merge(route_mode: "ha-routes")
    hooks = Sentinel::Hooks.new(dir: LoopTest.hooks_dir_for(cluster, tmp_state_dir),
                                log_dir: File.join(tmp_state_dir, "logs"),
                                env: { "STATE_DIR" => state.dir },
                                services_meta: { "_example" => { primary: "node-a", standby: "node-b" } },
                                timeout_s: 10, store: store)
    deciders = cluster.services.to_h do |name, service|
      [name, Sentinel::Decider.new(config: LoopTest.decider_config(service).merge(route_mode: "ha-routes"), state: state.for(name))]
    end
    loop_obj = Sentinel::Loop.new(
      config: config, cluster: cluster, store: store, state: state,
      probes: LoopTest::ProbesStub.new, gossip: LoopTest::GossipStub.new,
      lease: LoopTest::LeaseStub.new, hooks: hooks, deciders: deciders,
      notifier: ->(*) {}, now: clock.to_proc
    )
    { loop: loop_obj, state: state, config: config, clock: clock }
  end

  # The fixture's service is _example; the live legacy document describes opencode.
  def build_status
    Sentinel::Status.build(loop: @h[:loop], state: @h[:state], config: @h[:config], now: @h[:clock].now,
                           service: "_example")
  end

  def test_exact_key_order
    @h[:loop].cycle!
    assert_equal BASH_KEYS, build_status.keys
  end

  def test_compact_json_for_litestream_guard
    @h[:loop].cycle!
    json = Sentinel::Status.to_json(build_status)
    assert_includes json, '"mode":"node-a"', "compact JSON, no space after the colon"
    refute_includes json, ": "
  end

  def test_values_and_types
    @h[:loop].cycle!
    s = build_status
    assert_equal "node-a", s["mode"]
    assert_equal "up 1.0", s["primary_service"]
    assert_equal "1.0", s["primary_service_version"]
    assert_equal "up", s["primary_host"]
    assert_equal "ok", s["classification"]
    assert_equal 0, s["dead_polls"]
    assert_equal({ "ssh" => "up", "icmp" => "down", "traefik" => "down" }, s["host_probes"])
    assert_equal 2, s["poll_interval_s"]
    assert_equal 5, s["dead_confirm_polls"]
    assert_equal false, s["promoting"]
    assert_nil s["transition"]
    assert_equal "on", s["auto_promote"]
    assert_equal "on", s["auto_failback"]
    assert_equal false, s["hold"]
    assert_nil s["down_since"]
    assert_equal 60, s["promote_after_s"]
    assert_equal 0, s["promote_cooldown_left_s"]
    assert_equal 30, s["failback_after_s"]
    assert_equal 0, s["flips_in_window"]
    assert_nil s["standby_stack"]
    assert_equal "ha-routes", s["route_mode"]
    assert_equal "unknown", s["route_primary"], "bash parity: no ha-routes binary -> unknown"
    assert_nil s["ha_connectors"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, s["checked_at"])
    assert_equal 0, s["status_age_s"]
  end

  def test_mode_since_and_hold_overlay
    @h[:state].for("_example").set_mode!("node-b", now: @h[:clock].now)
    @h[:state].hold_on!("test")
    @h[:loop].cycle!
    s = build_status
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, s["since"], "since = mtime of state/mode")
    assert_equal true, s["hold"]
  end

  # The legacy document is a frozen contract: the exact bytes the pre-per-service-state code
  # produced for this scenario (test/fixtures/status_legacy.json, generated 2026-10-12).
  def test_legacy_document_is_byte_identical_to_the_fixture
    @h[:loop].cycle!
    st = @h[:state].for("_example")
    st.set_mode!("node-b", now: @h[:clock].now)
    t = Time.utc(2026, 1, 1, 11, 0, 0)
    File.utime(t, t, st.path("mode"))
    @h[:state].hold_on!("test", now: @h[:clock].now)
    File.write(st.path("stack"), "healthy\n")
    st.set_transition!("promote", "20260101T110000Z")
    @h[:loop].cycle!
    @h[:clock].advance(7)

    expected = File.read(File.expand_path("fixtures/status_legacy.json", __dir__)).strip
    assert_equal expected, Sentinel::Status.to_json(build_status)
  end

  def test_per_service_hold_and_transition_in_v1
    two = Sentinel::State.new(tmp_state_dir)
    two.for("_example").hold_on!("test")
    two.for("other").set_transition!("promote", "20260101T120000Z")
    v1 = Sentinel::Status.v1(loop: @h[:loop], state: two, now: @h[:clock].now)
    assert_equal true, v1[:services]["_example"][:hold]
    assert_equal false, v1[:hold], "the node-wide hold is off"
    assert_nil v1[:services]["_example"][:transition]
    assert_nil v1[:transition]
  end

  def test_status_age_advances
    @h[:loop].cycle!
    @h[:clock].advance(7)
    assert_equal 7, build_status["status_age_s"]
  end

  def test_no_cycle_yet_fallback
    s = build_status
    assert_equal "node-a", s["mode"]
    assert_equal "unknown", s["primary_service"]
    assert_equal false, s["promoting"]
    assert_equal "no cycle yet", s["note"]
  end

  def test_unknown_service_raises
    assert_raises(ArgumentError) do
      Sentinel::Status.build(loop: @h[:loop], state: @h[:state], config: @h[:config], service: "ghost")
    end
  end

  def test_v1_document
    @h[:loop].cycle!
    v1 = Sentinel::Status.v1(loop: @h[:loop], state: @h[:state], now: @h[:clock].now)
    assert v1[:ok]
    assert_equal "node-b", v1[:node]
    assert_equal "up", v1[:quorum]
    assert_equal 0, v1[:status_age_s]
    assert_equal %w[node-a node-b witness-1], v1[:hosts].keys
    assert_equal({ ssh: "up", icmp: nil, traefik: nil }, v1[:hosts]["node-a"][:probes])
    assert_equal({ "_example" => "up 1.0" }, v1[:hosts]["node-a"][:services])
    assert_equal({ "_example" => "ok" }, v1[:hosts]["witness-1"][:classes])
    e = v1[:services]["_example"]
    assert_equal "node-a", e[:primary]
    assert_equal "node-b", e[:standby]
    assert e[:acting]
    assert_equal "node-a", e[:mode]
    assert_equal "ok", e[:agreed_class]
    assert_equal "ok", e[:classification]
    assert_equal 0, e[:gates][:dead_polls]
    assert_equal false, e[:hold]
    refute v1.key?(:note)
    json = JSON.generate(v1)
    refute_match(/primary_|node_b_/, json.gsub(/"(node-a|node-b|witness-1)"/, ""), "neutral key names only")
  end

  def test_v1_before_first_cycle
    v1 = Sentinel::Status.v1(loop: @h[:loop], state: @h[:state], now: @h[:clock].now)
    assert v1[:ok]
    assert_equal "no cycle yet", v1[:note]
    assert_equal({}, v1[:hosts])
    assert_equal "node-a", v1[:services]["_example"][:mode]
    assert_nil v1[:at]
  end

  # The dashboard extras: lease (without its token), last transition, host roles, majority,
  # cluster-wide hold; all resolved from an explicit store/cluster when given.
  def test_v1_dashboard_fields
    store = Sentinel::Store.memory(node: "node-b")
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(LoopTest::CLUSTER_YML), node_name: "node-b")
    now = @h[:clock].now
    store.lease_grant!(service: "_example", holder: "node-b", action: "promote", token: "secret", ttl_s: 30, now: now)
    id = store.transition_start!(service: "_example", action: "promote")
    store.transition_end!(id, result: "ok", exit_code: 0, duration_s: 7)
    store.set("primary_at._example", "2026-01-01T11:00:00Z")
    @h[:state].hold_on!("test")
    @h[:loop].cycle!

    v1 = Sentinel::Status.v1(loop: @h[:loop], state: @h[:state], now: now, store: store, cluster: cluster)
    assert_equal true, v1[:hold]
    assert_equal cluster.majority, v1[:majority]
    assert_equal "witness", v1[:hosts]["witness-1"][:role]
    assert_equal "member", v1[:hosts]["node-a"][:role]
    e = v1[:services]["_example"]
    assert_equal "2026-01-01T11:00:00Z", e[:since]
    assert_equal "node-b", e[:lease][:holder]
    assert_equal "promote", e[:lease][:action]
    refute e[:lease].key?(:token), "the lease token never leaves the node"
    assert_equal "promote", e[:last_transition][:action]
    assert_equal "ok", e[:last_transition][:result]
    assert_equal 7, e[:last_transition][:data]["duration_s"]
    assert_nil e[:action_running]
    refute_match(/"token"/, JSON.generate(v1))
  end

  # The mode is read live from the state file, not the cycle snapshot: a transition hook moves
  # it while the loop is blocked inside the hook, and the guards' ExecCondition act on this
  # field (2026-10-13: the stale snapshot kept the standby refusing to start for 593 s).
  def test_mode_is_live_while_a_hook_holds_the_cycle
    @h[:loop].cycle!
    doc = Sentinel::Status.build(loop: @h[:loop], state: @h[:state], config: @h[:config],
                                 now: @h[:clock].now, service: "_example")
    assert_equal "node-a", doc["mode"]

    @h[:state].for("_example").set_mode!("node-b", now: @h[:clock].now) # what a running hook does
    doc = Sentinel::Status.build(loop: @h[:loop], state: @h[:state], config: @h[:config],
                                 now: @h[:clock].now, service: "_example")
    assert_equal "node-b", doc["mode"], "no new cycle ran, the mode must still be the live file"

    v1 = Sentinel::Status.v1(loop: @h[:loop], state: @h[:state], now: @h[:clock].now,
                             config: @h[:config])
    assert_equal "node-b", v1[:services]["_example"][:mode]
  end

end
