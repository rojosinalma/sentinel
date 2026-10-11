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
      service = cluster.services.values.first or raise Config::Error, "no services in cluster.yml"
      tunables = loop_config(cluster, service)
      store = Store.open(Config.fetch(:DB_PATH), node: cluster.node_name)
      state = State.new(Config.fetch(:STATE_DIR))
      gossip = Gossip.new(cluster: cluster, transport: Transport::Http.new(timeout: Config.fetch(:PEER_TIMEOUT_S)),
                          store: store, stale_s: Config.fetch(:PEER_STALE_S))
      lease = Lease.new(cluster: cluster, transport: Transport::Http.new(timeout: Config.fetch(:PEER_TIMEOUT_S)),
                        store: store, ttl_s: Config.fetch(:LEASE_TTL_S))
      hooks = Hooks.new(dir: File.expand_path("../../hooks", __dir__), log_dir: Config.fetch(:LOG_DIR),
                        env: hook_env(cluster, service, state), timeout_s: Config.fetch(:HOOK_TIMEOUT_S),
                        store: store)
      decider = Decider.new(config: tunables, state: state)
      loop = Loop.new(config: tunables, cluster: cluster, store: store, state: state,
                      probes: Probes, gossip: gossip, lease: lease, hooks: hooks,
                      decider: decider, notifier: notifier)

      @runtime = { cluster: cluster, service: service, config: tunables, store: store,
                   state: state, gossip: gossip, lease: lease, hooks: hooks, loop: loop }.freeze
      store.event!("boot", "sentinel up on #{cluster.node_name} (acting=#{loop.acting?})")
      $log.info "[boot] sentinel node=#{cluster.node_name} service=#{service.name} " \
                "acting=#{loop.acting?} majority=#{cluster.majority}"
      @runtime
    end

    def start_loop!
      boot!
      @runtime[:loop].start! if @runtime
    end

    def loop_config(cluster, service)
      basic = Config.fetch(:OPENCODE_SERVER_PASSWORD).then do |pass|
        pass.empty? ? nil : [Config.fetch(:OPENCODE_SERVER_USERNAME), pass]
      end
      {
        poll_interval_s: Config.fetch(:POLL_INTERVAL_S),
        tcp_timeout_s: Config.fetch(:TCP_TIMEOUT_S),
        http_timeout_s: Config.fetch(:HTTP_TIMEOUT_S),
        host_health_interval_s: Config.fetch(:HOST_HEALTH_INTERVAL_S),
        heartbeat_s: Config.fetch(:HEARTBEAT_S),
        lease_renew_s: Config.fetch(:LEASE_RENEW_S),
        auto_promote: Config.fetch(:AUTO_PROMOTE),
        auto_failback: Config.fetch(:AUTO_FAILBACK),
        basic: basic,
        primary: service.primary,
        standby: service.standby,
        service: service.name,
        label: "#{service.name}-#{service.standby}",
        quorum_targets: cluster.quorum_tcp,
        route_mode: Config.fetch(:ROUTE_MODE),
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

    def hook_env(cluster, service, state)
      {
        "ACTING_NODE" => cluster.node_name,
        "PRIMARY" => service.primary,
        "STANDBY" => service.standby,
        "STATE_DIR" => File.expand_path(state.dir)
      }.freeze
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
