# frozen_string_literal: true

require "time"

module Sentinel
  # An immutable snapshot of one host's probes at one instant. String values mirror the bash
  # sentinel exactly: opencode "up <ver>" | "up auth?" | "down" (nil when the host has no probed
  # service), ssh/icmp/traefik "up" | "down" (nil when not configured on the host).
  HostView = Struct.new(:name, :opencode, :ssh, :icmp, :traefik, :probed_at, keyword_init: true) do
    def service_up? = opencode.to_s.start_with?("up")

    def any_host_probe_up? = [ssh, icmp, traefik].any?("up")

    # The version out of "up <ver>"; nil for "down", "up auth?" and "up ?".
    def version
      v = opencode.to_s[/\Aup (.+)\z/, 1]
      v == "auth?" || v == "?" ? nil : v
    end

    def to_h
      {
        "name" => name, "opencode" => opencode, "ssh" => ssh, "icmp" => icmp,
        "traefik" => traefik, "probed_at" => probed_at&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
    end

    def self.from_h(hash)
      new(
        name: hash["name"], opencode: hash["opencode"], ssh: hash["ssh"], icmp: hash["icmp"],
        traefik: hash["traefik"],
        probed_at: hash["probed_at"] && Time.iso8601(hash["probed_at"])
      ).freeze
    end
  end
end
