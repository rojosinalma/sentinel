# frozen_string_literal: true

require_relative "test_helper"

class StateTest < Minitest::Test
  def setup
    @state = Sentinel::State.new(tmp_state_dir)
  end

  def test_mode_default_when_absent
    assert_equal "silver", @state.mode(default: "silver")
    assert_nil @state.mode_since
  end

  def test_set_mode_and_history
    clock = FakeClock.new
    @state.set_mode!("tiny", now: clock.now)
    assert_equal "tiny", @state.mode(default: "silver")
    assert_equal "tiny\n", File.read(@state.path("mode"))
    assert_equal "2026-01-01T12:00:00Z tiny", File.read(@state.path("mode.history")).strip
    refute_nil @state.mode_since
  end

  def test_legacy_primary_form
    File.write(@state.path("mode"), "primary=tiny since whenever\n")
    assert_equal "tiny", @state.mode(default: "silver")
  end

  def test_corrupt_mode_raises
    File.write(@state.path("mode"), "???\n")
    assert_raises(Sentinel::State::Corrupt) { @state.mode(default: "silver") }
  end

  def test_invalid_set_mode
    assert_raises(ArgumentError) { @state.set_mode!("Not Valid") }
  end

  def test_hold
    refute @state.hold?
    @state.hold_on!("rojo")
    assert @state.hold?
    assert_match(/rojo/, File.read(@state.path("hold")))
    @state.hold_off!
    refute @state.hold?
  end

  def test_transition
    assert_nil @state.transition
    File.write(@state.path("transition"), "promote 20260101T120000Z\n")
    assert_equal "promote 20260101T120000Z", @state.transition
  end

  def test_busy_with_flock
    refute @state.busy?, "no lock file -> not busy"
    lock = File.open(@state.path("promote.lock"), File::CREAT | File::RDWR)
    refute @state.busy?, "unlocked lock file -> not busy"
    lock.flock(File::LOCK_EX)
    assert @state.busy?, "held flock -> busy"
    lock.flock(File::LOCK_UN)
    refute @state.busy?
  ensure
    lock&.close
  end

  def test_file_age_s
    assert_equal Sentinel::State::ABSENT_AGE, @state.file_age_s("last-demote")
    @state.touch!("last-demote")
    past = Time.now - 100
    File.utime(past, past, @state.path("last-demote"))
    age = @state.file_age_s("last-demote")
    assert_in_delta 100, age, 2
    assert_equal 50, @state.file_age_s("last-demote", now: past + 50)
    @state.remove!("last-demote")
    assert_equal Sentinel::State::ABSENT_AGE, @state.file_age_s("last-demote")
  end

  def test_flips_in_window
    clock = FakeClock.new
    assert_equal 0, @state.flips_in_window(3600, now: clock.now)
    @state.set_mode!("tiny", now: clock.now - 7000)
    @state.set_mode!("silver", now: clock.now - 1800)
    @state.set_mode!("tiny", now: clock.now - 60)
    assert_equal 2, @state.flips_in_window(3600, now: clock.now)
    assert_equal 3, @state.flips_in_window(8000, now: clock.now)
  end

  # ---------------------------------------------------------------- per service

  def test_for_returns_the_same_service_state
    a = @state.for("opencode")
    assert_same a, @state.for("opencode")
    assert_instance_of Sentinel::ServiceState, a
    assert_equal "opencode", a.service
    assert_equal File.join(@state.dir, "opencode"), a.dir
    assert File.directory?(a.dir)
    assert_raises(ArgumentError) { @state.for("../escape") }
    assert_raises(ArgumentError) { @state.for("Bad Name") }
  end

  def test_services_are_isolated
    clock = FakeClock.new
    oc = @state.for("opencode")
    fleet = @state.for("fleet")
    fleet.set_mode!("tiny", now: clock.now)
    fleet.set_transition!("promote", "20260101T120000Z")
    fleet.touch!("promote-failed")
    File.write(fleet.path("stack"), "degraded: hangar\n")

    assert_equal "tiny", fleet.mode(default: "silver")
    assert_equal "silver", oc.mode(default: "silver"), "the other service's mode is untouched"
    assert_equal "silver", @state.mode(default: "silver"), "and so is the node root"
    assert_equal 1, fleet.flips_in_window(3600, now: clock.now)
    assert_equal 0, oc.flips_in_window(3600, now: clock.now)
    assert_equal "promote 20260101T120000Z", fleet.transition
    assert_nil oc.transition
    assert_equal 0, fleet.file_age_s("promote-failed", now: Time.now)
    assert_equal Sentinel::State::ABSENT_AGE, oc.file_age_s("promote-failed")
    assert_equal "degraded: hangar", fleet.stack
    assert_nil oc.stack
    fleet.clear_transition!
    assert_nil fleet.transition
  end

  def test_busy_is_per_service
    fleet = @state.for("fleet")
    lock = File.open(fleet.path("promote.lock"), File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)
    assert fleet.busy?
    refute @state.for("opencode").busy?
    refute @state.busy?
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_hold_is_node_wide_or_per_service
    oc = @state.for("opencode")
    fleet = @state.for("fleet")
    refute oc.hold?

    @state.hold_on!("rojo")
    assert oc.hold?, "node-wide hold covers every service"
    assert fleet.hold?
    refute File.exist?(oc.path("hold"))
    @state.hold_off!
    refute oc.hold?

    fleet.hold_on!("rojo")
    assert fleet.hold?
    refute oc.hold?, "a service hold is that service's alone"
    refute @state.hold?
    fleet.hold_off!
    refute fleet.hold?
  end

  # ---------------------------------------------------------------- migration

  def test_migrate_legacy_moves_the_opencode_files_and_leaves_a_mode_symlink
    clock = FakeClock.new
    @state.set_mode!("tiny", now: clock.now)
    %w[transition promote-failed tiny-stack last-demote last-stack-repair warm.json known_hosts].each do |n|
      File.write(@state.path(n), "#{n}\n")
    end
    @state.hold_on!("rojo")

    moved = @state.migrate_legacy!("opencode")
    oc = @state.for("opencode")
    assert_equal %w[mode mode.history transition promote-failed tiny-stack warm.json known_hosts
                    last-demote last-stack-repair].sort, moved.sort
    assert_equal "tiny", oc.mode(default: "silver")
    assert_equal "2026-01-01T12:00:00Z tiny", File.read(oc.path("mode.history")).strip
    assert_equal "tiny-stack", oc.stack
    assert File.file?(oc.path("last-demote"))
    assert File.symlink?(@state.path("mode"))
    assert_equal "opencode/mode", File.readlink(@state.path("mode"))
    assert_equal "tiny", @state.mode(default: "silver"), "external readers of state/mode still see it"
    assert @state.hold?, "the node-wide hold stays at the root"
    refute File.exist?(@state.path("transition"))

    # the hook moves the per-service file; the symlink follows
    oc.set_mode!("silver", now: clock.now)
    assert_equal "silver\n", File.read(@state.path("mode"))
    assert_equal [], @state.migrate_legacy!("opencode"), "a second run is a no-op"
  end

  def test_migrate_legacy_is_a_noop_without_legacy_files
    assert_equal [], @state.migrate_legacy!("opencode")
    refute File.exist?(@state.path("mode"))
    @state.for("opencode").set_mode!("tiny")
    File.write(@state.path("mode"), "silver\n")
    assert_equal [], @state.migrate_legacy!("opencode"), "never overwrites an existing per-service mode"
    assert_equal "tiny", @state.for("opencode").mode(default: "silver")
  end
end
