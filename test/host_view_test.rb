# frozen_string_literal: true

require_relative "test_helper"

class HostViewTest < Minitest::Test
  def view(**over)
    defaults = { name: "node-a", services: { "opencode" => "up 2.0.25" }, ssh: "up", icmp: "up",
                 traefik: "up", probed_at: Time.utc(2026, 1, 1, 12, 0, 0) }
    Sentinel::HostView.new(**defaults.merge(over)).freeze
  end

  def test_service_up
    assert view.service_up?("opencode")
    assert view(services: { "opencode" => "up auth?" }).service_up?("opencode")
    refute view(services: { "opencode" => "down" }).service_up?("opencode")
    refute view(services: {}).service_up?("opencode")
    refute view.service_up?("other"), "a service the host does not carry is not up"
  end

  def test_two_services_independent
    v = view(services: { "opencode" => "up 1.0", "other" => "down" })
    assert v.service_up?("opencode")
    refute v.service_up?("other")
    assert_equal "down", v.service_state("other")
    assert_nil v.service_state("ghost")
  end

  def test_any_host_probe_up
    assert view.any_host_probe_up?
    refute view(ssh: "down", icmp: "down", traefik: "down").any_host_probe_up?
    assert view(ssh: "down", icmp: "down", traefik: "up").any_host_probe_up?
    refute view(ssh: nil, icmp: nil, traefik: nil).any_host_probe_up?
  end

  def test_version
    assert_equal "2.0.25", view.version("opencode")
    assert_nil view(services: { "opencode" => "up auth?" }).version("opencode")
    assert_nil view(services: { "opencode" => "up ?" }).version("opencode")
    assert_nil view(services: { "opencode" => "down" }).version("opencode")
    assert_nil view(services: {}).version("opencode")
  end

  def test_to_h_from_h_roundtrip
    original = view
    hash = original.to_h
    assert_equal "node-a", hash["name"]
    assert_equal({ "opencode" => "up 2.0.25" }, hash["services"])
    assert_equal "2026-01-01T12:00:00Z", hash["probed_at"]
    restored = Sentinel::HostView.from_h(hash)
    assert_equal original.name, restored.name
    assert_equal original.services, restored.services
    assert_equal original.probed_at, restored.probed_at
  end

  def test_from_h_nil_probed_at
    restored = Sentinel::HostView.from_h({ "name" => "x" })
    assert_nil restored.probed_at
    assert_equal({}, restored.services)
  end
end
