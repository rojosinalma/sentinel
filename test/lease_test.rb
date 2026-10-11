# frozen_string_literal: true

require_relative "test_helper"
require "json"

class LeaseTest < Minitest::Test
  include ClusterHarness

  NODES = %w[silver tiny witness-1].freeze

  def setup
    @clock = FakeClock.new
    @stores = NODES.to_h { |n| [n, Sentinel::Store.memory(node: n)] }
    @down = []
    apps = NODES.to_h do |node|
      ["http://#{node}:4197", lambda do |method, path, body|
        raise "node #{node} is down" if @down.include?(node)

        case [method, path]
        in ["POST", "/peer/lease"] then pack(@leases[node].handle_request(body))
        in ["POST", "/peer/lease/release"] then pack(@leases[node].handle_release(body))
        else [404, "{}"]
        end
      end]
    end
    transport = Sentinel::Transport::InProcess.new(apps)
    @leases = NODES.to_h do |node|
      [node, Sentinel::Lease.new(cluster: cluster_for(node), transport: transport,
                                 store: @stores[node], ttl_s: 30, now: @clock.to_proc)]
    end
  end

  def pack((status, body)) = [status, JSON.generate(body)]

  def test_happy_acquire
    grant = @leases["tiny"].acquire!(service: "opencode", action: "promote")
    assert_equal %w[silver witness-1], grant.granted_by.sort
    refute_nil @stores["tiny"].lease_current("opencode", now: @clock.now)
    refute_nil @stores["silver"].lease_current("opencode", now: @clock.now)
    assert(@stores["silver"].events.any? { |e| e[:kind] == "lease.grant" })
  end

  def test_majority_with_one_peer_down
    @down << "silver"
    grant = @leases["tiny"].acquire!(service: "opencode", action: "promote")
    assert_equal %w[witness-1], grant.granted_by
  end

  def test_denied_without_majority
    @down.concat(%w[silver witness-1])
    err = assert_raises(Sentinel::Lease::Denied) do
      @leases["tiny"].acquire!(service: "opencode", action: "promote")
    end
    assert_equal 2, err.reasons.size
  end

  def test_denied_when_peers_hold_conflicting_lease
    %w[silver witness-1].each do |n|
      @stores[n].lease_grant!(service: "opencode", holder: "someone-else", action: "promote",
                              token: "other", ttl_s: 30, now: @clock.now)
    end
    err = assert_raises(Sentinel::Lease::Denied) do
      @leases["tiny"].acquire!(service: "opencode", action: "promote")
    end
    assert(err.reasons.all? { |r| r.include?("held by someone-else") })
  end

  def test_holder_must_be_standby
    status, body = @leases["silver"].handle_request(
      "service" => "opencode", "holder" => "silver", "action" => "promote", "ttl_s" => 30, "token" => "t"
    )
    assert_equal 409, status
    refute body[:ok]
    assert_match(/not the standby/, body[:message])
  end

  def test_unknown_service
    status, body = @leases["silver"].handle_request(
      "service" => "nope", "holder" => "tiny", "action" => "promote", "ttl_s" => 30, "token" => "t"
    )
    assert_equal 400, status
    refute body[:ok]
  end

  def test_renew_extends_and_expired_without_majority
    grant = @leases["tiny"].acquire!(service: "opencode", action: "promote")
    @clock.advance(10)
    renewed = @leases["tiny"].renew!(grant)
    assert_operator renewed.expires_at, :>, grant.expires_at

    @down.concat(%w[silver witness-1])
    assert_raises(Sentinel::Lease::Expired) { @leases["tiny"].renew!(renewed) }
  end

  def test_release
    grant = @leases["tiny"].acquire!(service: "opencode", action: "promote")
    @leases["tiny"].release!(grant)
    assert_nil @stores["tiny"].lease_current("opencode", now: @clock.now)
    assert_nil @stores["silver"].lease_current("opencode", now: @clock.now)
    assert_nil @stores["witness-1"].lease_current("opencode", now: @clock.now)
  end

  def test_expired_leases_do_not_block
    @stores["silver"].lease_grant!(service: "opencode", holder: "someone-else", action: "promote",
                                   token: "old", ttl_s: 30, now: @clock.now)
    @clock.advance(31)
    grant = @leases["tiny"].acquire!(service: "opencode", action: "promote")
    assert_includes grant.granted_by, "silver"
  end
end
