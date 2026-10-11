# frozen_string_literal: true

require "time"

module Sentinel
  # An immutable snapshot of one host's probes at one instant. String values mirror the bash
  # sentinel exactly: services {name => "up <ver>" | "up auth?" | "down"} (a host carries only
  # the services whose health URL names it), ssh/icmp/traefik "up" | "down" (nil when not
  # configured on the host).
  HostView = Struct.new(:name, :services, :ssh, :icmp, :traefik, :probed_at, keyword_init: true) do
    def initialize(services: {}, **rest)
      super(services: (services || {}).freeze, **rest)
    end

    def service_state(name) = services[name]

    def service_up?(name) = service_state(name).to_s.start_with?("up")

    def any_host_probe_up? = [ssh, icmp, traefik].any?("up")

    # The version out of "up <ver>"; nil for "down", "up auth?" and "up ?".
    def version(name)
      v = service_state(name).to_s[/\Aup (.+)\z/, 1]
      v == "auth?" || v == "?" ? nil : v
    end

    def to_h
      {
        "name" => name, "services" => services.dup, "ssh" => ssh, "icmp" => icmp,
        "traefik" => traefik, "probed_at" => probed_at&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
    end

    def self.from_h(hash)
      new(
        name: hash["name"], services: hash["services"] || {}, ssh: hash["ssh"], icmp: hash["icmp"],
        traefik: hash["traefik"],
        probed_at: hash["probed_at"] && Time.iso8601(hash["probed_at"])
      ).freeze
    end
  end
end
