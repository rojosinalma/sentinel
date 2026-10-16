# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  def setup
    @store = Sentinel::Store.memory(node: "node-b")
  end

  def test_migrations_idempotent_on_file
    path = File.join(tmp_state_dir, "s.db")
    Sentinel::Store.open(path)
    store = Sentinel::Store.open(path)
    assert_empty store.events
  end

  def test_event_roundtrip
    id = @store.event!("decision", "promoting", host: "node-a", service: "opencode", down_for: 61)
    assert_kind_of Integer, id
    ev = @store.events.first
    assert_equal "decision", ev[:kind]
    assert_equal "promoting", ev[:message]
    assert_equal "node-b", ev[:node]
    assert_equal "node-a", ev[:host]
    assert_equal({ "down_for" => 61 }, ev[:data])
  end

  def test_events_filter
    @store.event!("gate", "cooldown")
    @store.event!("decision", "promote")
    assert_equal 1, @store.events(kind: "gate").size
    assert_equal 2, @store.events.size
  end

  def test_events_filter_by_service
    @store.event!("decision", "a", service: "opencode")
    @store.event!("decision", "b", service: "hangar")
    @store.event!("boot", "node-level")
    assert_equal %w[a], @store.events(service: "opencode").map { |e| e[:message] }
    assert_equal %w[b], @store.events(service: "hangar", kind: "decision").map { |e| e[:message] }
    assert_equal 3, @store.events.size, "no filter = every row incl. node-level ones"
  end

  def test_transitions
    id = @store.transition_start!(service: "opencode", action: "promote", log_file: "/tmp/x.log")
    @store.transition_end!(id, result: "ok", exit_code: 0, duration_s: 9.5)
    row = @store.transitions(service: "opencode").first
    assert_equal "promote", row[:action]
    assert_equal "ok", row[:result]
    assert_equal 0, row[:exit_code]
    assert_equal({ "duration_s" => 9.5 }, row[:data])
    refute_nil row[:finished_at]
  end

  def test_get_set
    assert_nil @store.get("primary.opencode")
    @store.set("primary.opencode", "node-a")
    assert_equal "node-a", @store.get("primary.opencode")
    @store.set("primary.opencode", "node-b")
    assert_equal "node-b", @store.get("primary.opencode")
  end

  def test_lease_grant_conflict_and_extend
    clock = FakeClock.new
    row = @store.lease_grant!(service: "opencode", holder: "node-b", action: "promote",
                              token: "t1", ttl_s: 30, granted_by: %w[node-a witness-1], now: clock.now)
    assert_equal "node-b", row[:holder]

    err = assert_raises(Sentinel::Store::LeaseHeld) do
      @store.lease_grant!(service: "opencode", holder: "node-a", action: "demote",
                          token: "t2", ttl_s: 30, now: clock.now)
    end
    assert_match(/held by node-b/, err.message)

    extended = @store.lease_grant!(service: "opencode", holder: "node-b", action: "promote",
                                   token: "t1", ttl_s: 30, now: clock.now + 10)
    assert_operator extended[:expires_at], :>, row[:expires_at]

    clock.advance(100)
    assert_nil @store.lease_current("opencode", now: clock.now)
    row2 = @store.lease_grant!(service: "opencode", holder: "node-a", action: "demote",
                               token: "t3", ttl_s: 30, now: clock.now)
    assert_equal "node-a", row2[:holder]
  end

  def test_lease_release
    @store.lease_grant!(service: "opencode", holder: "node-b", action: "promote", token: "tok", ttl_s: 30)
    refute_nil @store.lease_current("opencode")
    @store.lease_release!("tok")
    assert_nil @store.lease_current("opencode")
  end

  def test_peer_views_upsert
    @store.peer_view_put!("node-a", at: "2026-01-01T00:00:00Z", body: '{"node":"node-a"}')
    @store.peer_view_put!("node-a", at: "2026-01-01T00:00:05Z", body: '{"node":"node-a","x":1}')
    views = @store.peer_views
    assert_equal 1, views.size
    assert_equal "2026-01-01T00:00:05Z", views.first[:at]
  end

  def test_prune
    @store.db[:events].insert(at: "2020-01-01T00:00:00Z", kind: "old", level: "info")
    @store.event!("new", "fresh")
    out = @store.prune!(keep_days: 30)
    assert_equal 1, out[:events]
    assert_equal 1, @store.events.size
  end
end
