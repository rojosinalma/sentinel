# frozen_string_literal: true

require_relative "test_helper"

class StateTest < Minitest::Test
  def setup
    @state = Sentinel::State.new(tmp_state_dir)
  end

  def test_mode_default_when_absent
    assert_equal "node-a", @state.mode(default: "node-a")
    assert_nil @state.mode_since
  end

  def test_set_mode_and_history
    clock = FakeClock.new
    @state.set_mode!("node-b", now: clock.now)
    assert_equal "node-b", @state.mode(default: "node-a")
    assert_equal "node-b\n", File.read(@state.path("mode"))
    assert_equal "2026-01-01T12:00:00Z node-b", File.read(@state.path("mode.history")).strip
    refute_nil @state.mode_since
  end

  def test_legacy_primary_form
    File.write(@state.path("mode"), "primary=node-b since whenever\n")
    assert_equal "node-b", @state.mode(default: "node-a")
  end

  def test_corrupt_mode_raises
    File.write(@state.path("mode"), "???\n")
    assert_raises(Sentinel::State::Corrupt) { @state.mode(default: "node-a") }
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
    @state.set_mode!("node-b", now: clock.now - 7000)
    @state.set_mode!("node-a", now: clock.now - 1800)
    @state.set_mode!("node-b", now: clock.now - 60)
    assert_equal 2, @state.flips_in_window(3600, now: clock.now)
    assert_equal 3, @state.flips_in_window(8000, now: clock.now)
  end
end
