# frozen_string_literal: true

module Sentinel
  # Builds the runtime from Config and starts the loop thread. A node without NODE_NAME (the
  # plain standby-status page) boots nothing and every sentinel route answers 503.
  class << self
    attr_reader :runtime

    def enabled? = !ENV["NODE_NAME"].to_s.strip.empty?

    def boot!
      return nil unless enabled?
      return @runtime if @runtime

      cluster = Config.cluster
      raise Config::Error, "no services in cluster.yml" if cluster.services.empty?

      tunables = loop_config(cluster)
      store = Store.open(Config.fetch(:DB_PATH), node: cluster.node_name)
      state = State.new(Config.fetch(:STATE_DIR))
      state.migrate_legacy!(Status::LEGACY_SERVICE)
      gossip = Gossip.new(cluster: cluster, transport: Transport::Http.new(timeout: Config.fetch(:PEER_TIMEOUT_S)),
                          store: store, stale_s: Config.fetch(:PEER_STALE_S))
      lease = Lease.new(cluster: cluster, transport: Transport::Http.new(timeout: Config.fetch(:PEER_TIMEOUT_S)),
                        store: store, ttl_s: Config.fetch(:LEASE_TTL_S))
      hooks = Hooks.new(dir: File.expand_path("../../hooks", __dir__), log_dir: Config.fetch(:LOG_DIR),
                        env: hook_env(cluster, state), services_meta: services_meta(cluster),
                        timeout_s: Config.fetch(:HOOK_TIMEOUT_S), store: store)
      deciders = cluster.services.to_h do |name, service|
        [name, Decider.new(config: decider_config(tunables, service), state: state.for(name))]
      end
      loop = Loop.new(config: tunables, cluster: cluster, store: store, state: state,
                      probes: Probes, gossip: gossip, lease: lease, hooks: hooks,
                      deciders: deciders, notifier: notifier)

      @runtime = { cluster: cluster, config: tunables, store: store,
                   state: state, gossip: gossip, lease: lease, hooks: hooks, loop: loop }.freeze
      acting = loop.acting_services
      store.event!("boot", "sentinel up on #{cluster.node_name} (acting for #{acting.empty? ? 'none' : acting.join(',')})")
      $log.info "[boot] sentinel node=#{cluster.node_name} services=#{cluster.services.keys.join(',')} " \
                "acting=#{acting.join(',')} majority=#{cluster.majority}"
      @runtime
    end

    def start_loop!
      boot!
      @runtime[:loop].start! if @runtime
    end

    # The node-wide tunables; the per-service Decider gets these plus decider_config.
    def loop_config(cluster)
      {
        poll_interval_s: Config.fetch(:POLL_INTERVAL_S),
        tcp_timeout_s: Config.fetch(:TCP_TIMEOUT_S),
        http_timeout_s: Config.fetch(:HTTP_TIMEOUT_S),
        host_health_interval_s: Config.fetch(:HOST_HEALTH_INTERVAL_S),
        heartbeat_s: Config.fetch(:HEARTBEAT_S),
        lease_renew_s: Config.fetch(:LEASE_RENEW_S),
        auto_promote: Config.fetch(:AUTO_PROMOTE),
        auto_failback: Config.fetch(:AUTO_FAILBACK),
        events_keep_days: Config.fetch(:EVENTS_KEEP_DAYS),
        quorum_targets: cluster.quorum_tcp,
        route_mode: Config.fetch(:ROUTE_MODE),
        ha_routes_bin: Config.fetch(:HA_ROUTES_BIN),
        route_timeout_s: Config.fetch(:ROUTE_TIMEOUT_S),
        promote_after_s: Config.fetch(:PROMOTE_AFTER_S),
        failback_after_s: Config.fetch(:FAILBACK_AFTER_S),
        promote_cooldown_s: Config.fetch(:PROMOTE_COOLDOWN_S),
        promote_retry_s: Config.fetch(:PROMOTE_RETRY_S),
        failback_retry_s: Config.fetch(:FAILBACK_RETRY_S),
        flap_flips: Config.fetch(:FLAP_FLIPS),
        flap_window_s: Config.fetch(:FLAP_WINDOW_S),
        flap_failback_after_s: Config.fetch(:FLAP_FAILBACK_AFTER_S),
        dead_confirm_polls: Config.fetch(:DEAD_CONFIRM_POLLS),
        notify_down_after_s: Config.fetch(:NOTIFY_DOWN_AFTER_S),
        fence_interval_s: Config.fetch(:FENCE_INTERVAL_S),
        stack_check_interval_s: Config.fetch(:STACK_CHECK_INTERVAL_S)
      }.freeze
    end

    # Node-wide tunables, overridden by the service's cluster.yml `tunables`/`auto_promote`.
    def decider_config(tunables, service)
      tunables.merge(service.tunables || {}).merge(
        primary: service.primary,
        standby: service.standby,
        service: service.name,
        label: "#{service.name}-#{service.standby}",
        auto_promote: service.auto_promote.nil? ? tunables[:auto_promote] : (service.auto_promote ? "on" : "off")
      ).freeze
    end

    # Node-wide hook environment; PRIMARY/STANDBY come from services_meta per run.
    def hook_env(cluster, state)
      {
        "ACTING_NODE" => cluster.node_name,
        "STATE_DIR" => File.expand_path(state.dir),
        "SN_ENV" => ENV.fetch("SN_ENV", File.expand_path("../../.env", __dir__))
      }.freeze
    end

    # hooks_dir from cluster.yml, relative to the repo root (default hooks/<service>).
    def services_meta(cluster)
      root = File.expand_path("../..", __dir__)
      cluster.services.transform_values do |s|
        { primary: s.primary, standby: s.standby,
          hooks_dir: File.expand_path(s.hooks_dir || File.join("hooks", s.name), root) }.freeze
      end.freeze
    end

    # Best-effort, the bash notify(): Discord and/or Apprise when configured, otherwise a log line.
    def notifier
      discord = Config.fetch(:DISCORD_WEBHOOK_URL)
      apprise = Config.fetch(:APPRISE_URL)
      transport = Transport::Http.new(timeout: 10)
      lambda do |title, body, type|
        sent = false
        unless apprise.empty?
          transport.post(apprise, { title: title, body: body, type: type, format: "text" })
          sent = true
        end
        unless discord.empty?
          transport.post(discord, { content: "**#{title}**\n#{body}" })
          sent = true
        end
        $log.info "[notify] (no webhook configured) #{title}: #{body}" unless sent
      end
    end
  end
end
