# frozen_string_literal: true

require_relative "test_helper"

class HostViewTest < Minitest::Test
  def view(**over)
    defaults = { name: "node-a", opencode: "up 2.0.25", ssh: "up", icmp: "up",
                 traefik: "up", probed_at: Time.utc(2026, 1, 1, 12, 0, 0) }
    Sentinel::HostView.new(**defaults.merge(over)).freeze
  end

  def test_service_up
    assert view.service_up?
    assert view(opencode: "up auth?").service_up?
    refute view(opencode: "down").service_up?
    refute view(opencode: nil).service_up?
  end

  def test_any_host_probe_up
    assert view.any_host_probe_up?
    refute view(ssh: "down", icmp: "down", traefik: "down").any_host_probe_up?
    assert view(ssh: "down", icmp: "down", traefik: "up").any_host_probe_up?
    refute view(ssh: nil, icmp: nil, traefik: nil).any_host_probe_up?
  end

  def test_version
    assert_equal "2.0.25", view.version
    assert_nil view(opencode: "up auth?").version
    assert_nil view(opencode: "up ?").version
    assert_nil view(opencode: "down").version
    assert_nil view(opencode: nil).version
  end

  def test_to_h_from_h_roundtrip
    original = view
    hash = original.to_h
    assert_equal "node-a", hash["name"]
    assert_equal "2026-01-01T12:00:00Z", hash["probed_at"]
    restored = Sentinel::HostView.from_h(hash)
    assert_equal original.name, restored.name
    assert_equal original.opencode, restored.opencode
    assert_equal original.probed_at, restored.probed_at
  end

  def test_from_h_nil_probed_at
    restored = Sentinel::HostView.from_h({ "name" => "x" })
    assert_nil restored.probed_at
  end
end
