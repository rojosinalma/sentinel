# frozen_string_literal: true

require "json"

module Sentinel
  # Builds the /status document byte-compatible with the bash sentinel: same keys, same order,
  # same types, compact JSON. Consumers that depend on it: opencode-guard (.mode), litestream-guard
  # (substring '"mode":"tiny"' on the raw response), Gatus 79 (ha_connectors, route_primary == mode),
  # opencode-tiny bin/verify, and the standby-status page (21 keys by name).
  module Status
    module_function

    # loop: Sentinel::Loop (its #last may be nil before the first cycle); state: Sentinel::State;
    # config: the same tunables Hash the loop got; now: Time source.
    def build(loop:, state:, config:, now: Time.now)
      doc = loop.last
      return no_cycle_yet(loop: loop, state: state, now: now) unless doc

      primary = loop.service.primary
      view = doc[:views][primary]
      snap = doc[:decider]

      {
        "mode" => doc[:mode],
        "since" => iso_or_nil(state.mode_since),
        "silver_opencode" => view&.opencode || "down",
        "silver_opencode_version" => view&.version,
        "silver_host" => view&.ssh || "down",
        "silver_host_health" => snap[:host_health],
        "quorum" => doc[:quorum],
        "classification" => snap[:classification],
        "dead_polls" => snap[:dead_polls],
        "host_probes" => {
          "ssh" => view&.ssh || "down",
          "icmp" => view&.icmp || "down",
          "traefik" => view&.traefik || "down"
        },
        "poll_interval_s" => config[:poll_interval_s],
        "dead_confirm_polls" => config[:dead_confirm_polls],
        "promoting" => state.busy?,
        "transition" => state.transition,
        "auto_promote" => config[:auto_promote],
        "auto_failback" => config[:auto_failback],
        "hold" => state.hold?,
        "down_since" => snap[:down_since],
        "promote_after_s" => config[:promote_after_s],
        "promote_cooldown_left_s" => snap[:promote_cooldown_left_s],
        "promote_retry_left_s" => snap[:promote_retry_left_s],
        "silver_stable_since" => snap[:stable_since],
        "failback_after_s" => snap[:failback_after_s],
        "failback_retry_left_s" => snap[:failback_retry_left_s],
        "flips_in_window" => snap[:flips_in_window],
        "tiny_stack" => doc[:tiny_stack],
        "route_mode" => config[:route_mode],
        "route_primary" => doc[:route_primary],
        "ha_connectors" => doc[:ha_connectors],
        "checked_at" => iso_or_nil(doc[:at]),
        "status_age_s" => (now - doc[:at]).to_i
      }
    end

    def to_json(status) = JSON.generate(status)

    # The bash fallback before the first cycle, with the live overlays status-http applied.
    def no_cycle_yet(loop:, state:, now:)
      {
        "mode" => state.mode(default: loop.service.primary),
        "since" => iso_or_nil(state.mode_since),
        "silver_opencode" => "unknown",
        "promoting" => state.busy?,
        "hold" => state.hold?,
        "transition" => state.transition,
        "note" => "no cycle yet",
        "status_age_s" => nil
      }
    end

    def iso_or_nil(time) = time&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
