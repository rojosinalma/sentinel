# frozen_string_literal: true

require "json"

module Sentinel
  # Builds the legacy /status document: a FROZEN CONTRACT — same keys, same order, same types,
  # compact JSON (external guards read .mode, match the raw '"mode":"…"' substring and compare
  # route_primary with mode). test/fixtures/status_legacy.json pins it.
  #
  # The legacy document describes one service (LEGACY_SERVICE, default: the first service in
  # cluster.yml); `v1` is the generic multi-service document behind /api/v1/status.
  module Status
    module_function

    # The service the legacy document, the CLI and the MCP tools default to.
    def legacy_service
      name = Config.fetch(:LEGACY_SERVICE)
      name.empty? ? Config.cluster.services.keys.first : name
    end

    # loop: Sentinel::Loop (its #last may be nil before the first cycle); state: Sentinel::State;
    # config: the same tunables Hash the loop got; now: Time source; service: the service the
    # legacy document describes.
    def build(loop:, state:, config:, now: Time.now, service: legacy_service)
      doc = loop.last
      svc = loop.services.fetch(service) { raise ArgumentError, "unknown service #{service.inspect}" }
      return no_cycle_yet(service: svc, state: state, loop: loop) unless doc

      entry = doc[:services].fetch(service)
      view = doc[:views][svc.primary]
      snap = entry[:decider]
      live = mode_source(loop: loop, service: svc, state: state)
      state = state.for(service)

      {
        "mode" => live[:mode],
        "since" => iso_or_nil(live[:since]),
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
          "https" => view&.https || "down"
        },
        "poll_interval_s" => config[:poll_interval_s],
        "dead_confirm_polls" => config[:dead_confirm_polls],
        "promoting" => live[:promoting],
        "transition" => live[:transition],
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
        "route_primary" => route_primary_for(doc, service),
        "ha_connectors" => doc[:ha_connectors],
        "checked_at" => iso_or_nil(doc[:at]),
        "status_age_s" => (now - doc[:at]).to_i
      }
    end

    def to_json(status) = JSON.generate(status)

    # Before the first cycle: the minimal document plus the live mode overlays.
    def no_cycle_yet(service:, state:, loop:)
      live = mode_source(loop: loop, service: service, state: state)
      {
        "mode" => live[:mode],
        "since" => iso_or_nil(live[:since]),
        "primary_service" => "unknown",
        "promoting" => live[:promoting],
        "hold" => state.for(service.name).hold?,
        "transition" => live[:transition],
        "note" => "no cycle yet",
        "status_age_s" => nil
      }
    end

    # Where mode/since/transition/promoting come from: {mode:, since: Time|nil, transition:, promoting:}.
    #
    # The acting node reads its state files live, not the cycle snapshot: a transition hook
    # writes the mode mid-run while the loop is blocked inside it, and external guards act on
    # this field (2026-10-13: the stale snapshot kept a unit skipped through a whole promote).
    #
    # Every other node has no state files for the service (only the acting node's hooks write
    # them), so it reports the acting node's gossip view — newest primary_at wins, its
    # per-service transition — then the store, then the configured primary
    # (in a drill the primary host's own /status reported itself as the mode throughout the
    # standby's promote, and its guard started the service mid-demote).
    def mode_source(loop:, service:, state:)
      if loop.acting?(service.name)
        sstate = state.for(service.name)
        { mode: sstate.mode(default: service.primary), since: sstate.mode_since,
          transition: sstate.transition, promoting: sstate.busy? }
      else
        rep = loop.replicated_primary(service)
        { mode: rep[:mode], since: rep[:since], transition: rep[:transition], promoting: !rep[:transition].nil? }
      end
    end

    # The generic document: every host's probes and service states, every service's decision
    # state. Neutral names only; nothing here depends on which host plays which role.
    #
    # store/cluster/config feed the dashboard extras (lease, last transition, host roles,
    # majority, the timer targets); callers that have only loop/state get them from the booted
    # runtime, and a bare harness (no runtime, nothing passed) simply leaves those fields nil.
    def v1(loop:, state:, now: Time.now, store: nil, cluster: nil, config: nil)
      runtime = Sentinel.respond_to?(:runtime) ? Sentinel.runtime : nil
      store ||= runtime && runtime[:store]
      cluster ||= runtime && runtime[:cluster]
      config ||= (runtime && runtime[:config]) || {}
      doc = loop.last
      action_running = defined?(Actions) ? Actions.running : {}
      services = loop.services.to_h do |name, svc|
        entry = doc&.dig(:services, name)
        sstate = state.for(name)
        live = mode_source(loop: loop, service: svc, state: state) # same sources as the legacy doc
        [name, {
          primary: svc.primary, standby: svc.standby, acting: loop.acting?(name),
          mode: live[:mode],
          since: (loop.acting?(name) && store && store.get("primary_at.#{name}")) || iso_or_nil(live[:since]),
          agreed_class: entry && entry[:agreed_class]&.to_s,
          classification: entry&.dig(:decider, :classification),
          gates: entry ? entry[:decider] : {},
          busy: entry ? entry[:busy] : sstate.busy?,
          standby_stack: entry && entry[:standby_stack],
          hold: sstate.hold?, transition: live[:transition],
          action_running: action_running[name],
          route_primary: doc && route_primary_for(doc, name),
          routes: svc.routes && { mode: svc.routes.mode, group: svc.routes.group, pihole_names: svc.routes.pihole_names },
          url: svc.url, host_urls: svc.host_urls,
          lease: store && lease_public(store.lease_current(name, now: now)),
          last_transition: store && store.transitions(service: name, limit: 1).first
        }]
      end
      hosts = (doc ? doc[:views] : {}).to_h do |name, view|
        [name, { role: cluster && cluster.hosts[name]&.role&.to_s,
                 probes: { ssh: view.ssh, icmp: view.icmp, https: view.https },
                 services: view.services,
                 classes: (doc[:classes] || {}).filter_map { |svc, by_host| [svc, by_host[name].to_s] if by_host[name] }.to_h }]
      end
      out = {
        ok: true, node: loop.node_name, at: iso_or_nil(doc && doc[:at]),
        status_age_s: doc && (now - doc[:at]).to_i,
        quorum: doc && doc[:quorum], reachable_peers: doc ? doc[:reachable_peers] : [],
        majority: cluster&.majority, hold: state.hold?,
        transition: services.values.filter_map { |e| e[:transition] }.first,
        tunables: config.slice(:poll_interval_s, :promote_after_s, :failback_after_s, :auto_promote, :auto_failback),
        hosts: hosts, services: services,
        route_primary: doc && doc[:route_primary], ha_connectors: doc && doc[:ha_connectors]
      }
      out[:note] = "no cycle yet" unless doc
      out
    end

    # The lease row without its bearer token (the token authorises the release call).
    def lease_public(row)
      return nil unless row

      row.reject { |k, _| k == :token }
    end

    # The loop records one route primary per service (Hash); a plain String is the pre-group shape.
    def route_primary_for(doc, service)
      rp = doc[:route_primary]
      rp.is_a?(Hash) ? rp[service] : rp
    end

    def iso_or_nil(time) = time&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
