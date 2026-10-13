# frozen_string_literal: true

require_relative "test_helper"
require_relative "loop_test"
require "yaml"

class ActionsTest < Minitest::Test
  # node-b acts for both services, so one node can hold two transition slots.
  TWO_ON_NODE_B_YML = LoopTest::CLUSTER_YML + <<~YAML.gsub(/^/, "  ")
    _second:
      primary: node-a
      standby: node-b
      health: {node-a: "http://127.0.0.1:3/api/info", node-b: "http://127.0.0.2:3/api/info"}
  YAML

  def setup
    @root = tmp_state_dir
    @state = Sentinel::State.new(File.join(@root, "state"))
    @store = Sentinel::Store.memory(node: "node-b")
    cluster = Sentinel::Config::Cluster.new(YAML.safe_load(TWO_ON_NODE_B_YML), node_name: "node-b")
    hooks_dir = File.join(@root, "hooks")
    cluster.services.each_key do |name|
      FileUtils.mkdir_p(File.join(hooks_dir, name))
      File.write(File.join(hooks_dir, name, "promote"),
                 "#!/usr/bin/env bash\nsleep ${SLEEP_S:-1}\n" \
                 "echo \"$STANDBY\" > \"$STATE_DIR/mode\"\n")
      FileUtils.chmod(0o755, File.join(hooks_dir, name, "promote"))
    end
    hooks = Sentinel::Hooks.new(dir: hooks_dir, log_dir: File.join(@root, "logs"),
                                env: { "STATE_DIR" => @state.dir, "SLEEP_S" => "1" },
                                services_meta: cluster.services.transform_values { |s| { primary: s.primary, standby: s.standby } },
                                timeout_s: 10, store: @store)
    deciders = cluster.services.to_h do |name, service|
      [name, Sentinel::Decider.new(config: LoopTest.decider_config(service), state: @state.for(name))]
    end
    loop_obj = Sentinel::Loop.new(config: LoopTest::CONFIG, cluster: cluster, store: @store, state: @state,
                                  probes: LoopTest::ProbesStub.new, gossip: LoopTest::GossipStub.new,
                                  lease: LoopTest::LeaseStub.new, hooks: hooks, deciders: deciders,
                                  notifier: ->(*) {})
    @rt = { cluster: cluster, state: @state, store: @store, hooks: hooks, loop: loop_obj }
  end

  def wait_idle
    deadline = Time.now + 10
    sleep 0.05 while Time.now < deadline && !Sentinel::Actions.running.empty?
    assert_empty Sentinel::Actions.running
  end

  def test_one_slot_per_service
    ok, = Sentinel::Actions.transition!(@rt, "_example", "promote")
    assert ok
    assert_equal({ "_example" => "promote" }, Sentinel::Actions.running)

    ok, msg = Sentinel::Actions.transition!(@rt, "_example", "promote")
    refute ok
    assert_match(/_example transition .*already running/, msg)

    ok, = Sentinel::Actions.transition!(@rt, "_second", "promote")
    assert ok, "the other service has its own slot"
    assert_equal %w[_example _second], Sentinel::Actions.running.keys.sort

    wait_idle
    assert_equal "node-b", @state.for("_example").mode(default: "node-a")
    assert_equal "node-b", @state.for("_second").mode(default: "node-a")
    assert_equal %w[_example _second], @store.transitions.map { |r| r[:service] }.sort
  end

  def test_busy_lock_of_one_service_does_not_block_the_other
    lock = File.open(@state.for("_example").path("promote.lock"), File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)
    ok, msg = Sentinel::Actions.transition!(@rt, "_example", "promote")
    refute ok
    assert_match(/lock held/, msg)

    ok, = Sentinel::Actions.transition!(@rt, "_second", "promote")
    assert ok
    wait_idle
    assert_equal "node-a", @state.for("_example").mode(default: "node-a"), "untouched"
    assert_equal "node-b", @state.for("_second").mode(default: "node-a")
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_hold_node_wide_or_per_service
    Sentinel::Actions.hold!(@rt, on: true, who: "test")
    assert @state.hold?
    assert @state.for("_second").hold?
    Sentinel::Actions.hold!(@rt, on: false, who: "test")
    refute @state.hold?

    ok, msg = Sentinel::Actions.hold!(@rt, on: true, who: "test", service: "_second")
    assert ok
    assert_equal "_second hold on", msg
    assert @state.for("_second").hold?
    refute @state.for("_example").hold?
    refute @state.hold?
    assert_equal "_second", @store.events(kind: "hold").first[:service]
  end
end
