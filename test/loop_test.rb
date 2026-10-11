# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class LoopTest < Minitest::Test
  CLUSTER_YML = <<~YAML
    hosts:
      silver:   {address: 127.0.0.1, sentinel_url: http://silver:4197, role: member, probes: {ssh: 22}}
      tiny:     {address: 127.0.0.2, sentinel_url: http://tiny:4197, role: member, probes: {ssh: 22}}
      witness-1: {address: 127.0.0.3, sentinel_url: http://witness-1:4197, role: witness, probes: {ssh: 22}}
    quorum_tcp: []
    services:
      _example:
        primary: silver
        standby: tiny
        health: {silver: "http://127.0.0.1:1/api/info", tiny: "http://127.0.0.2:1/api/info"}
        hooks_dir: hooks/_example
  YAML

  # Scripted probes: flip `down` to take silver's service away (host probes stay up -> degraded).
  class ProbesStub
    attr_accessor :down

    def initialize = @down = false

    def host(host, service_url: nil, basic: nil, timeout: nil, now: Time.now)
      service = if service_url
                  host.name == "silver" && @down ? "down" : "up 1.0"
                end
      Sentinel::HostView.new(name: host.name, opencode: service, ssh: "up", icmp: nil,
                             traefik: nil, probed_at: now).freeze
    end

    def quorum(_targets, timeout:) = "up"
  end

  class GossipStub
    def poll! = nil
    def quorum? = true
    def agreed_class(_host, local) = local
    def primary(_service) = nil
    def reachable_peers = []
    def local_view(**) = {}
  end

  class LeaseStub
    attr_reader :acquired, :released

    def initialize
      @acquired = []
      @released = []
    end

    def acquire!(service:, action:)
      @acquired << action
      Sentinel::Lease::Grant.new(service: service, action: action, token: "tok",
                                 expires_at: "x", granted_by: ["witness-1"]).freeze
    end

    def renew!(grant) = grant
    def release!(grant) = @released << grant.token
  end

  class DenyingLease
    def acquire!(service:, action:)
      raise Sentinel::Lease::Denied, ["silver: held by someone", "witness-1: no answer"]
    end
  end

  CONFIG = {
    poll_interval_s: 2, tcp_timeout_s: 1, http_timeout_s: 1, host_health_interval_s: 15,
    heartbeat_s: 300, lease_renew_s: 60, auto_promote: "on", auto_failback: "on", basic: nil,
    primary: "silver", standby: "tiny", service: "_example", label: "example",
    quorum_targets: [], promote_after_s: 60, failback_after_s: 30, promote_cooldown_s: 120,
    promote_retry_s: 120, failback_retry_s: 300, flap_flips: 3, flap_window_s: 3600,
    flap_failback_after_s: 600, dead_confirm_polls: 5, notify_down_after_s: 60,
    fence_interval_s: 60, stack_check_interval_s: 30
  }.freeze

  def build_loop(node: "tiny", lease: LeaseStub.new)
    clock = FakeClock.new
    state = Sentinel::State.new(tmp_state_dir)
    store = Sentinel::Store.memory(node: node)
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(CLUSTER_YML), node_name: node)
    probes = ProbesStub.new
    hooks = Sentinel::Hooks.new(
      dir: File.expand_path("../hooks", __dir__), log_dir: File.join(tmp_state_dir, "logs"),
      env: { "ACTING_NODE" => node, "PRIMARY" => "silver", "STANDBY" => "tiny",
             "STATE_DIR" => state.dir },
      timeout_s: 10, store: store
    )
    decider = Sentinel::Decider.new(config: CONFIG, state: state)
    notifications = []
    loop_obj = Sentinel::Loop.new(
      config: CONFIG, cluster: cluster, store: store, state: state, probes: probes,
      gossip: GossipStub.new, lease: lease, hooks: hooks, decider: decider,
      notifier: ->(t, b, y) { notifications << [t, b, y] }, now: clock.to_proc
    )
    { loop: loop_obj, clock: clock, state: state, store: store, probes: probes,
      lease: lease, notifications: notifications }
  end

  def test_healthy_cycle
    h = build_loop
    h[:loop].cycle!
    last = h[:loop].last
    assert_equal "silver", last[:mode]
    assert_equal :ok, last[:agreed_class]
    assert last[:acting]
    refute last[:busy]
    assert_equal "up", last[:quorum]
  end

  def test_full_promote_path
    h = build_loop
    h[:loop].cycle!
    h[:probes].down = true
    h[:loop].cycle! # degraded, down_since starts
    assert_equal :degraded, h[:loop].last[:agreed_class]
    assert_equal "silver", h[:loop].last[:mode]

    h[:clock].advance(61)
    h[:loop].cycle! # past PROMOTE_AFTER_S -> promote hook runs

    assert_equal "tiny", h[:state].mode(default: "silver"), "promote hook wrote mode"
    assert_equal "tiny", h[:loop].last[:mode]
    assert_equal "tiny", h[:store].get("primary._example")
    assert_equal ["promote"], h[:lease].acquired
    assert_equal ["tok"], h[:lease].released

    row = h[:store].transitions(service: "_example").first
    assert_equal "promote", row[:action]
    assert_equal "ok", row[:result]

    assert(h[:notifications].any? { |(t, _b, _y)| t == "silver _example down" })
    assert(h[:store].events(kind: "class.change").any?)
  end

  def test_failback_path
    h = build_loop
    h[:state].set_mode!("tiny", now: h[:clock].now)

    h[:loop].cycle! # standby cycle; health hook -> host_health up; stable timer starts
    assert_equal "tiny", h[:loop].last[:mode]

    h[:clock].advance(31)
    h[:loop].cycle! # stable past FAILBACK_AFTER_S -> demote hook

    assert_equal "silver", h[:state].mode(default: "silver"), "demote hook wrote mode back"
    assert_includes h[:lease].acquired, "demote"
    row = h[:store].transitions(service: "_example").first
    assert_equal "demote", row[:action]
  end

  def test_busy_short_circuits
    h = build_loop
    lock = File.open(File.join(h[:state].dir, "promote.lock"), File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)

    h[:probes].down = true
    h[:loop].cycle!
    h[:clock].advance(120)
    h[:loop].cycle!

    assert h[:loop].last[:busy]
    assert_empty h[:lease].acquired, "no action while a hook holds the lock"
    assert_empty h[:store].transitions
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_non_acting_node_never_acts
    h = build_loop(node: "silver")
    refute h[:loop].acting?
    h[:probes].down = true
    h[:loop].cycle!
    h[:clock].advance(120)
    h[:loop].cycle!

    assert_empty h[:lease].acquired
    assert_empty h[:store].transitions
    assert_equal "silver", h[:loop].last[:mode], "non-acting falls back to service.primary"
    refute h[:loop].last[:acting]
  end

  def test_lease_denied_blocks_and_notifies
    h = build_loop(lease: DenyingLease.new)
    h[:loop].cycle!
    h[:probes].down = true
    h[:loop].cycle!
    h[:clock].advance(61)
    h[:loop].cycle!

    assert_equal "silver", h[:state].mode(default: "silver"), "no promote without a lease"
    assert_empty h[:store].transitions
    assert(h[:store].events(kind: "lease.deny").any?)
    assert(h[:notifications].any? { |(t, _b, _y)| t.include?("blocked") })
  end
end
