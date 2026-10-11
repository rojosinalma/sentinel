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

  # Two services with opposite roles: tiny acts for _example, silver acts for _example2.
  TWO_SERVICES_YML = CLUSTER_YML + <<~YAML.gsub(/^/, "  ")
    _example2:
      primary: tiny
      standby: silver
      health: {silver: "http://127.0.0.1:2/api/info", tiny: "http://127.0.0.2:2/api/info"}
      hooks_dir: hooks/_example2
  YAML

  # Scripted probes: take_down(host, service) takes one service on one host away (host probes
  # stay up -> degraded).
  class ProbesStub
    def initialize = @down = []

    def take_down(host, service) = @down << "#{host}/#{service}"
    def restore(host, service) = @down.delete("#{host}/#{service}")

    def host(host, service_urls: {}, basic: nil, timeout: nil, now: Time.now)
      services = service_urls.keys.to_h do |svc|
        [svc, @down.include?("#{host.name}/#{svc}") ? "down" : "up 1.0"]
      end
      Sentinel::HostView.new(name: host.name, services: services, ssh: "up", icmp: nil,
                             traefik: nil, probed_at: now).freeze
    end

    def quorum(_targets, timeout:) = "up"
  end

  class GossipStub
    def poll! = nil
    def quorum? = true
    def agreed_class(_service, _host, local) = local
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
      @acquired << [service, action]
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
    events_keep_days: 30, quorum_targets: [], promote_after_s: 60, failback_after_s: 30,
    promote_cooldown_s: 120, promote_retry_s: 120, failback_retry_s: 300, flap_flips: 3,
    flap_window_s: 3600, flap_failback_after_s: 600, dead_confirm_polls: 5, notify_down_after_s: 60,
    fence_interval_s: 60, stack_check_interval_s: 30
  }.freeze

  # Per-service Decider config, the shape boot.rb's decider_config produces.
  def self.decider_config(service)
    CONFIG.merge(primary: service.primary, standby: service.standby, service: service.name,
                 label: "#{service.name}-#{service.standby}").freeze
  end

  # A hooks dir where every service of the cluster is the _example hook set (hooks/ is not
  # ours to extend in tests).
  def self.hooks_dir_for(cluster, root)
    dir = File.join(root, "hooks")
    FileUtils.mkdir_p(dir)
    cluster.services.each_key do |name|
      File.symlink(File.expand_path("../hooks/_example", __dir__), File.join(dir, name))
    end
    dir
  end

  def build_loop(node: "tiny", lease: LeaseStub.new, cluster_yml: CLUSTER_YML)
    clock = FakeClock.new
    state = Sentinel::State.new(tmp_state_dir)
    store = Sentinel::Store.memory(node: node)
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(cluster_yml), node_name: node)
    probes = ProbesStub.new
    log_dir = File.join(tmp_state_dir, "logs")
    hooks = Sentinel::Hooks.new(
      dir: self.class.hooks_dir_for(cluster, tmp_state_dir), log_dir: log_dir,
      env: { "ACTING_NODE" => node, "STATE_DIR" => state.dir },
      services_meta: cluster.services.transform_values { |s| { primary: s.primary, standby: s.standby } },
      timeout_s: 10, store: store
    )
    deciders = cluster.services.to_h do |name, service|
      [name, Sentinel::Decider.new(config: self.class.decider_config(service), state: state)]
    end
    notifications = []
    loop_obj = Sentinel::Loop.new(
      config: CONFIG, cluster: cluster, store: store, state: state, probes: probes,
      gossip: GossipStub.new, lease: lease, hooks: hooks, deciders: deciders,
      notifier: ->(t, b, y) { notifications << [t, b, y] }, now: clock.to_proc
    )
    { loop: loop_obj, clock: clock, state: state, store: store, probes: probes,
      lease: lease, notifications: notifications, log_dir: log_dir }
  end

  def svc(h, name = "_example") = h[:loop].last[:services][name]

  def test_healthy_cycle
    h = build_loop
    h[:loop].cycle!
    last = h[:loop].last
    assert_equal "tiny", last[:node]
    assert_equal "up", last[:quorum]
    assert_equal %w[_example], last[:services].keys
    e = svc(h)
    assert_equal "silver", e[:mode]
    assert_equal :ok, e[:agreed_class]
    assert e[:acting]
    refute e[:busy]
    assert_equal({ "silver" => :ok, "tiny" => :ok, "witness-1" => :ok }, last[:classes]["_example"])
    assert_equal "up 1.0", last[:views]["silver"].service_state("_example")
  end

  def test_full_promote_path
    h = build_loop
    h[:loop].cycle!
    h[:probes].take_down("silver", "_example")
    h[:loop].cycle! # degraded, down_since starts
    assert_equal :degraded, svc(h)[:agreed_class]
    assert_equal "silver", svc(h)[:mode]

    h[:clock].advance(61)
    h[:loop].cycle! # past PROMOTE_AFTER_S -> promote hook runs

    assert_equal "tiny", h[:state].mode(default: "silver"), "promote hook wrote mode"
    assert_equal "tiny", svc(h)[:mode]
    assert_equal "tiny", h[:store].get("primary._example")
    assert_equal [["_example", "promote"]], h[:lease].acquired
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
    assert_equal "tiny", svc(h)[:mode]

    h[:clock].advance(31)
    h[:loop].cycle! # stable past FAILBACK_AFTER_S -> demote hook

    assert_equal "silver", h[:state].mode(default: "silver"), "demote hook wrote mode back"
    assert_includes h[:lease].acquired, ["_example", "demote"]
    row = h[:store].transitions(service: "_example").first
    assert_equal "demote", row[:action]
  end

  def test_busy_short_circuits
    h = build_loop
    lock = File.open(File.join(h[:state].dir, "promote.lock"), File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)

    h[:probes].take_down("silver", "_example")
    h[:loop].cycle!
    h[:clock].advance(120)
    h[:loop].cycle!

    assert svc(h)[:busy]
    assert_empty h[:lease].acquired, "no action while a hook holds the lock"
    assert_empty h[:store].transitions
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_non_acting_node_never_acts
    h = build_loop(node: "silver")
    refute h[:loop].acting?("_example")
    assert_empty h[:loop].acting_services
    h[:probes].take_down("silver", "_example")
    h[:loop].cycle!
    h[:clock].advance(120)
    h[:loop].cycle!

    assert_empty h[:lease].acquired
    assert_empty h[:store].transitions
    assert_equal "silver", svc(h)[:mode], "non-acting falls back to service.primary"
    refute svc(h)[:acting]
  end

  def test_lease_denied_blocks_and_notifies
    h = build_loop(lease: DenyingLease.new)
    h[:loop].cycle!
    h[:probes].take_down("silver", "_example")
    h[:loop].cycle!
    h[:clock].advance(61)
    h[:loop].cycle!

    assert_equal "silver", h[:state].mode(default: "silver"), "no promote without a lease"
    assert_empty h[:store].transitions
    assert(h[:store].events(kind: "lease.deny").any?)
    assert(h[:notifications].any? { |(t, _b, _y)| t.include?("blocked") })
  end

  def test_watch_maintenance_runs_replicate_warm_on_the_primary_cadence
    h = build_loop
    h[:loop].cycle!
    log = File.join(h[:log_dir], "replicate.log")
    assert File.file?(log), "first primary cycle ran the replicate hook"
    assert_equal 1, File.readlines(log).grep(/args=warm/).size

    h[:clock].advance(2)
    h[:loop].cycle!
    assert_equal 1, File.readlines(log).grep(/args=warm/).size, "not due yet"

    h[:clock].advance(30)
    h[:loop].cycle!
    assert_equal 2, File.readlines(log).grep(/args=warm/).size, "STACK_CHECK_INTERVAL_S later"
    assert_empty h[:store].transitions, "maintenance is not a transition"
    assert_empty h[:lease].acquired, "and needs no lease"
  end

  def test_prune_runs_once_a_day
    h = build_loop
    h[:loop].cycle!
    assert_equal 1, h[:store].events(kind: "prune").size
    h[:clock].advance(3600)
    h[:loop].cycle!
    assert_equal 1, h[:store].events(kind: "prune").size
    h[:clock].advance(86_400)
    h[:loop].cycle!
    assert_equal 2, h[:store].events(kind: "prune").size
  end

  # ---------------------------------------------------------------- two services

  def test_two_services_each_get_their_own_decider_mode_and_acting_flag
    h = build_loop(cluster_yml: TWO_SERVICES_YML)
    assert h[:loop].acting?("_example")
    refute h[:loop].acting?("_example2")
    assert_equal %w[_example], h[:loop].acting_services

    h[:loop].cycle!
    last = h[:loop].last
    assert_equal %w[_example _example2], last[:services].keys
    assert_equal "silver", svc(h, "_example")[:mode]
    assert_equal "tiny", svc(h, "_example2")[:mode], "the other service's primary is tiny"
    assert svc(h, "_example")[:acting]
    refute svc(h, "_example2")[:acting]
    assert_equal({ "silver" => :ok, "tiny" => :ok, "witness-1" => :ok }, last[:classes]["_example2"])
    assert_equal({ "_example" => "up 1.0", "_example2" => "up 1.0" }, last[:views]["tiny"].services)
    assert_equal({}, last[:views]["witness-1"].services)

    # the warm upkeep only runs for the service this node acts for
    assert_equal 1, File.readlines(File.join(h[:log_dir], "replicate.log")).grep(/SERVICE=_example /).size
    assert_empty File.readlines(File.join(h[:log_dir], "replicate.log")).grep(/SERVICE=_example2/)
  end

  def test_two_services_outage_of_one_leaves_the_other_alone
    h = build_loop(cluster_yml: TWO_SERVICES_YML)
    h[:loop].cycle!
    h[:probes].take_down("silver", "_example")
    h[:loop].cycle!
    assert_equal :degraded, svc(h, "_example")[:agreed_class]
    assert_equal :ok, svc(h, "_example2")[:agreed_class], "silver carries _example2 too, but it still answers"
    assert_equal :degraded, h[:loop].last[:classes]["_example"]["silver"]
    assert_equal :ok, h[:loop].last[:classes]["_example2"]["silver"]

    h[:clock].advance(61)
    h[:loop].cycle!
    assert_equal [["_example", "promote"]], h[:lease].acquired
    assert_equal "tiny", svc(h, "_example")[:mode]
    assert_equal "tiny", h[:store].get("primary._example")
    assert_nil h[:store].get("primary._example2"), "nothing happened to the other service"
    assert_equal "tiny", svc(h, "_example2")[:mode]
    assert_equal %w[_example], h[:store].transitions.map { |r| r[:service] }.uniq
    degraded = h[:store].events(kind: "class.change").select { |e| e[:message].include?("-> degraded") }
    assert_equal ["_example"], degraded.map { |e| e[:service] }.uniq
  end

  def test_two_services_the_other_node_acts_for_the_other_service
    h = build_loop(node: "silver", cluster_yml: TWO_SERVICES_YML)
    refute h[:loop].acting?("_example")
    assert h[:loop].acting?("_example2")
    h[:loop].cycle!
    assert_equal "tiny", svc(h, "_example2")[:mode]
    assert_equal "silver", svc(h, "_example")[:mode]

    # _example goes down on silver: silver is not the acting node for it -> observe only
    h[:probes].take_down("silver", "_example")
    h[:loop].cycle!
    h[:clock].advance(61)
    h[:loop].cycle!
    assert_empty h[:lease].acquired
    assert_equal :degraded, svc(h, "_example")[:agreed_class]

    # _example2 goes down on tiny: silver acts
    h[:probes].take_down("tiny", "_example2")
    h[:loop].cycle!
    h[:clock].advance(61)
    h[:loop].cycle!
    assert_equal [["_example2", "promote"]], h[:lease].acquired
    assert_equal "silver", h[:state].mode(default: "tiny"), "the hook wrote STANDBY=silver"
    assert_equal "silver", svc(h, "_example2")[:mode]
    assert_equal "silver", h[:store].get("primary._example2")
    assert_equal "silver", svc(h, "_example")[:mode], "non-acting service unaffected"
    assert(h[:notifications].any? { |(t, _b, _y)| t == "tiny _example2 down" })
  end

  def test_execute_transition_takes_the_service
    h = build_loop(cluster_yml: TWO_SERVICES_YML)
    result = h[:loop].execute_transition!("_example", "promote", ["--auto"])
    assert_equal 0, result.exit_code
    assert_equal [["_example", "promote"]], h[:lease].acquired
    assert_equal "tiny", h[:store].get("primary._example")
    assert_raises(KeyError) { h[:loop].execute_transition!("ghost", "promote") }
  end
end
