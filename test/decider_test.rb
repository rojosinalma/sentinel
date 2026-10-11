# frozen_string_literal: true

require_relative "test_helper"

class DeciderTest < Minitest::Test
  CONFIG = {
    primary: "silver", standby: "tiny", service: "opencode", label: "opencode-tiny",
    quorum_targets: ["10.0.0.3:53"],
    promote_after_s: 60, failback_after_s: 30, promote_cooldown_s: 120, promote_retry_s: 120,
    failback_retry_s: 300, flap_flips: 3, flap_window_s: 3600, flap_failback_after_s: 600,
    dead_confirm_polls: 5, notify_down_after_s: 60, fence_interval_s: 60, stack_check_interval_s: 30
  }.freeze

  def setup
    @clock = FakeClock.new
    @state = Sentinel::State.new(tmp_state_dir)
    @decider = Sentinel::Decider.new(config: CONFIG, state: @state)
  end

  def step(mode: "silver", agreed_class: :ok, quorum: "up", auto_promote: "on",
           auto_failback: "on", host_health: nil, **extra)
    @decider.step(now: @clock.now, mode: mode, agreed_class: agreed_class, quorum: quorum,
                  auto_promote: auto_promote, auto_failback: auto_failback,
                  host_health: host_health, **extra)
  end

  def test_promote_after_sustained_degraded
    assert_equal :none, step.action
    r = step(agreed_class: :degraded)
    assert_equal :none, r.action
    assert(r.log.any? { |l| l.include?("DOWN: degraded") })

    @clock.advance(59)
    assert_equal :none, step(agreed_class: :degraded).action

    @clock.advance(2)
    r = step(agreed_class: :degraded)
    assert_equal :promote, r.action
    assert_equal "degraded", r.gates[:classification]
  end

  def test_dead_path_promote_fast
    4.times do
      assert_equal :none, step(agreed_class: :dead).action
      @clock.advance(2)
    end
    r = step(agreed_class: :dead)
    assert_equal :promote_fast, r.action
    assert_equal 5, r.gates[:dead_polls]
    assert(r.log.any? { |l| l.include?("DEAD confirmed") })
  end

  def test_degraded_resets_dead_counter
    3.times { step(agreed_class: :dead); @clock.advance(2) }
    r = step(agreed_class: :degraded)
    assert(r.log.any? { |l| l.include?("dead counter reset from 3") })
    5.times { @clock.advance(2); step(agreed_class: :dead) }
    # counter restarted: 5 dead polls reached again -> fast promote (down_for is irrelevant for dead)
    assert_equal :promote_fast, step(agreed_class: :dead).action
  end

  def test_isolated_notifies_once_and_never_acts
    r = step(agreed_class: :isolated, quorum: "down")
    assert_equal :none, r.action
    assert_equal 1, r.notify.size
    assert_match(/isolated/, r.notify.first[0])

    @clock.advance(300)
    r = step(agreed_class: :isolated, quorum: "down")
    assert_equal :none, r.action
    assert(r.notify.none? { |(t, _b, _y)| t.include?("isolated") }, "isolated notify is once")
  end

  def test_down_notify_and_back_notify
    step(agreed_class: :degraded)
    @clock.advance(61)
    r = step(agreed_class: :degraded, quorum: "down") # quorum down also gates the promote
    assert(r.notify.any? { |(t, _b, y)| t == "silver opencode down" && y == "warning" })

    @clock.advance(10)
    r = step(agreed_class: :ok, version: "2.0.25")
    assert_equal :none, r.action
    assert(r.notify.any? { |(t, b, y)| t == "silver opencode back" && b.include?("2.0.25") && y == "success" })
  end

  def test_no_back_notify_without_down_notify
    step(agreed_class: :degraded)
    @clock.advance(10) # below notify_down_after_s
    r = step(agreed_class: :ok)
    assert_empty r.notify
  end

  def test_gate_auto_promote_off
    step(agreed_class: :degraded)
    @clock.advance(61)
    r = step(agreed_class: :degraded, auto_promote: "off")
    assert_equal :none, r.action
    assert(r.log.any? { |l| l.include?("AUTO_PROMOTE=off") })
  end

  def test_gate_quorum
    step(agreed_class: :degraded)
    @clock.advance(61)
    r = step(agreed_class: :degraded, quorum: "down")
    assert_equal :none, r.action
    assert(r.log.any? { |l| l.include?("no quorum") })
  end

  def test_gate_cooldown_after_failback
    @state.touch!("last-demote")
    File.utime(@clock.now, @clock.now, @state.path("last-demote"))
    step(agreed_class: :degraded)
    @clock.advance(61)
    r = step(agreed_class: :degraded)
    assert_equal :none, r.action
    assert_operator r.gates[:promote_cooldown_left_s], :>, 0
    assert(r.log.any? { |l| l.include?("cooldown") })
  end

  def test_gate_promote_retry
    @state.touch!("promote-failed")
    File.utime(@clock.now, @clock.now, @state.path("promote-failed"))
    step(agreed_class: :degraded)
    @clock.advance(61)
    r = step(agreed_class: :degraded)
    assert_equal :none, r.action
    assert(r.log.any? { |l| l.include?("retry in") })

    # marker aging past PROMOTE_RETRY_S unblocks
    old = @clock.now - 300
    File.utime(old, old, @state.path("promote-failed"))
    @clock.advance(61)
    assert_equal :promote, step(agreed_class: :degraded).action
  end

  def test_failback_after_stable
    r = step(mode: "tiny", host_health: "up")
    assert_equal :fence_and_route, r.action, "first standby cycle fences"
    assert(r.log.any? { |l| l.include?("silver host healthy") })

    @clock.advance(10)
    assert_equal :stack_check, step(mode: "tiny", host_health: "up").action

    @clock.advance(21) # stable 31s >= 30
    r = step(mode: "tiny", host_health: "up")
    assert_equal :failback, r.action
  end

  def test_failback_stable_reset_on_unhealthy
    step(mode: "tiny", host_health: "up")
    @clock.advance(20)
    r = step(mode: "tiny", host_health: "down docker")
    assert(r.log.any? { |l| l.include?("counter reset") })
    @clock.advance(20)
    r = step(mode: "tiny", host_health: "up")
    refute_equal :failback, r.action, "stable timer restarted"
  end

  def test_failback_blocked_by_hold_notifies_once
    @state.hold_on!("rojo")
    step(mode: "tiny", host_health: "up")
    @clock.advance(31)
    r = step(mode: "tiny", host_health: "up")
    refute_equal :failback, r.action
    assert(r.notify.any? { |(t, _b, _y)| t.include?("failback on hold") })

    @clock.advance(10)
    r = step(mode: "tiny", host_health: "up")
    assert(r.notify.none? { |(t, _b, _y)| t.include?("hold") }, "hold notify is once")

    @state.hold_off!
    @clock.advance(10)
    assert_equal :failback, step(mode: "tiny", host_health: "up").action
  end

  def test_failback_blocked_by_auto_off_and_retry
    step(mode: "tiny", host_health: "up")
    @clock.advance(31)
    r = step(mode: "tiny", host_health: "up", auto_failback: "off")
    refute_equal :failback, r.action
    assert(r.log.any? { |l| l.include?("AUTO_FAILBACK=off") })

    @state.touch!("failback-failed")
    @clock.advance(10)
    r = step(mode: "tiny", host_health: "up")
    refute_equal :failback, r.action
    assert_operator r.gates[:failback_retry_left_s], :>, 0
  end

  def test_flap_damping
    3.times do |i|
      @state.set_mode!(i.even? ? "tiny" : "silver", now: @clock.now - 600 + (i * 60))
    end
    all_notifies = step(mode: "tiny", host_health: "up").notify
    @clock.advance(100) # past 30s but below 600s
    r = step(mode: "tiny", host_health: "up")
    all_notifies += r.notify
    refute_equal :failback, r.action
    assert_equal 600, r.gates[:failback_after_s]
    @clock.advance(10)
    all_notifies += step(mode: "tiny", host_health: "up").notify
    assert_equal 1, all_notifies.count { |(t, _b, _y)| t.include?("flapping") }, "flap notify once"
  end

  def test_snapshot_fields
    step(agreed_class: :degraded)
    snap = @decider.snapshot(now: @clock.now)
    assert_equal "degraded", snap[:classification]
    refute_nil snap[:down_since]
    assert_equal 0, snap[:dead_polls]
    assert_equal 30, snap[:failback_after_s]
    assert_includes snap.keys, :promote_cooldown_left_s
  end

  def test_mode_switch_resets
    step(agreed_class: :dead)
    @decider.reset_for_mode!("tiny")
    snap = @decider.snapshot(now: @clock.now)
    assert_equal "ok", snap[:classification]
    assert_equal 0, snap[:dead_polls]
    assert_nil snap[:down_since]
  end
end
