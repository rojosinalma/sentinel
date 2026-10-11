# frozen_string_literal: true

require "json"

module Sentinel
  # Builds the /status document byte-compatible with the bash sentinel: same keys, same order,
  # same types, compact JSON. Consumers that depend on it: service-guard (.mode), replica-guard
  # (substring '"mode":"node-b"' on the raw response), Gatus 79 (ha_connectors, route_primary == mode),
  # opencode-node-b bin/verify, and the standby-status page (21 keys by name).
  #
  # The legacy document describes one service (the opencode-era contract); `v1` is the generic
  # multi-service document behind /api/v1/status.
  module Status
    LEGACY_SERVICE = "opencode"

    module_function

    # loop: Sentinel::Loop (its #last may be nil before the first cycle); state: Sentinel::State;
    # config: the same tunables Hash the loop got; now: Time source; service: the service the
    # legacy document describes.
    def build(loop:, state:, config:, now: Time.now, service: LEGACY_SERVICE)
      doc = loop.last
      svc = loop.services.fetch(service) { raise ArgumentError, "unknown service #{service.inspect}" }
      return no_cycle_yet(service: svc, state: state) unless doc

      entry = doc[:services].fetch(service)
      view = doc[:views][svc.primary]
      snap = entry[:decider]

      {
        "mode" => entry[:mode],
        "since" => iso_or_nil(state.mode_since),
        "primary_service" => view&.service_state(service) || "down",
        "primary_service_version" => view&.version(service),
        "primary_host" => view&.ssh || "down",
        "primary_host_health" => snap[:host_health],
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
        "primary_stable_since" => snap[:stable_since],
        "failback_after_s" => snap[:failback_after_s],
        "failback_retry_left_s" => snap[:failback_retry_left_s],
        "flips_in_window" => snap[:flips_in_window],
        "standby_stack" => entry[:standby_stack],
        "route_mode" => config[:route_mode],
        "route_primary" => doc[:route_primary],
        "ha_connectors" => doc[:ha_connectors],
        "checked_at" => iso_or_nil(doc[:at]),
        "status_age_s" => (now - doc[:at]).to_i
      }
    end

    def to_json(status) = JSON.generate(status)

    # The bash fallback before the first cycle, with the live overlays status-http applied.
    def no_cycle_yet(service:, state:)
      {
        "mode" => state.mode(default: service.primary),
        "since" => iso_or_nil(state.mode_since),
        "primary_service" => "unknown",
        "promoting" => state.busy?,
        "hold" => state.hold?,
        "transition" => state.transition,
        "note" => "no cycle yet",
        "status_age_s" => nil
      }
    end

    # The generic document: every host's probes and service states, every service's decision
    # state. Neutral names only; nothing here depends on which host plays which role.
    def v1(loop:, state:, now: Time.now)
      doc = loop.last
      services = loop.services.to_h do |name, svc|
        entry = doc&.dig(:services, name)
        [name, {
          primary: svc.primary, standby: svc.standby, acting: loop.acting?(name),
          mode: entry ? entry[:mode] : state.mode(default: svc.primary),
          agreed_class: entry && entry[:agreed_class]&.to_s,
          classification: entry&.dig(:decider, :classification),
          gates: entry ? entry[:decider] : {},
          busy: entry ? entry[:busy] : state.busy?,
          standby_stack: entry && entry[:standby_stack],
          hold: state.hold?, transition: state.transition
        }]
      end
      hosts = (doc ? doc[:views] : {}).to_h do |name, view|
        [name, { probes: { ssh: view.ssh, icmp: view.icmp, traefik: view.traefik },
                 services: view.services,
                 classes: (doc[:classes] || {}).filter_map { |svc, by_host| [svc, by_host[name].to_s] if by_host[name] }.to_h }]
      end
      out = {
        ok: true, node: loop.node_name, at: iso_or_nil(doc && doc[:at]),
        status_age_s: doc && (now - doc[:at]).to_i,
        quorum: doc && doc[:quorum], reachable_peers: doc ? doc[:reachable_peers] : [],
        hosts: hosts, services: services,
        route_primary: doc && doc[:route_primary], ha_connectors: doc && doc[:ha_connectors]
      }
      out[:note] = "no cycle yet" unless doc
      out
    end

    def iso_or_nil(time) = time&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
