# frozen_string_literal: true

require "yaml"
require "uri"

module Sentinel
  # Typed-default config in the style of the legacy ::Config, plus the cluster table from
  # config/cluster.yml. Every tunable is overridable via ENV (.env through dotenv).
  module Config
    class Error < StandardError; end

    DEFAULTS = {
      "NODE_NAME"               => "",
      "CLUSTER_FILE"            => "config/cluster.yml",
      "POLL_INTERVAL_S"         => 2,
      "DEAD_CONFIRM_POLLS"      => 5,
      "DEGRADED_CONFIRM_POLLS"  => 1,
      "PROMOTE_AFTER_S"         => 60,
      "FAILBACK_AFTER_S"        => 30,
      "PROMOTE_COOLDOWN_S"      => 120,
      "PROMOTE_RETRY_S"         => 120,
      "FAILBACK_RETRY_S"        => 300,
      "FLAP_FLIPS"              => 3,
      "FLAP_WINDOW_S"           => 3600,
      "FLAP_FAILBACK_AFTER_S"   => 600,
      "HOST_HEALTH_INTERVAL_S"  => 15,
      "FENCE_INTERVAL_S"        => 60,
      "STACK_CHECK_INTERVAL_S"  => 30,
      "NOTIFY_DOWN_AFTER_S"     => 60,
      "HEARTBEAT_S"             => 300,
      "AUTO_PROMOTE"            => "on",
      "AUTO_FAILBACK"           => "on",
      "TCP_TIMEOUT_S"           => 2,
      "HTTP_TIMEOUT_S"          => 5,
      "PEER_TIMEOUT_S"          => 2,
      "FORWARD_TIMEOUT_S"       => 60,
      "PEER_STALE_S"            => 10,
      "LEASE_TTL_S"             => 30,
      "LEASE_RENEW_S"           => 10,
      "HOOK_TIMEOUT_S"          => 900,
      "STATE_DIR"               => "data/state",
      "LOG_DIR"                 => "data/logs",
      "DB_PATH"                 => "data/sentinel.db",
      "EVENTS_KEEP_DAYS"        => 30,
      "SENTINEL_PORT"           => 4197,
      "DISCORD_WEBHOOK_URL"     => "",
      "APPRISE_URL"             => "",
      "ROUTE_MODE"              => "off",
      "HA_ROUTES_BIN"           => "",
      "ROUTES_ENV_FILE"         => "",
      "HA_TUNNEL_ID"            => "",
      "CF_API_TOKEN"            => "",
      "CF_ACCOUNT_ID"           => "",
      "ROUTE_TIMEOUT_S"         => 60,
      "LEGACY_SERVICE"          => "",
      "LEGACY_REDIRECT_FROM"    => "",
      "LEGACY_REDIRECT_TO"      => "",
      "LOG_LEVEL"               => "info"
    }.freeze

    Host = Struct.new(:name, :address, :sentinel_url, :role, :probes, keyword_init: true) do
      def witness? = role == :witness
    end

    # How a service's health URLs are probed: basic = [user, pass] resolved from the env vars
    # named in cluster.yml (nil when the password is empty), extra request headers,
    # resolve = {host => ip} for URLs whose hostname is the same on every host, and
    # tls_verify (default true; false for self-signed health endpoints).
    Probe = Struct.new(:basic, :headers, :resolve, :tls_verify, keyword_init: true) do
      def resolve_ip(host) = resolve[host]
    end

    # Decider timers a service may override in cluster.yml (`tunables:`); the rest is node-wide.
    # probe_timeout_s is consumed by the probe fan-out (loop), degraded_confirm_polls by the
    # decider: both exist because one slow-but-healthy service may need a laxer probe than
    # the node-wide default without touching every other check.
    SERVICE_TUNABLES = %i[promote_after_s failback_after_s promote_cooldown_s promote_retry_s
                          failback_retry_s flap_flips flap_window_s flap_failback_after_s
                          dead_confirm_polls degraded_confirm_polls probe_timeout_s
                          notify_down_after_s fence_interval_s
                          stack_check_interval_s host_health_interval_s].freeze

    # How a service's public hostnames follow its primary: mode ha-routes (the core runs
    # `ha-routes set <host> --group <group>`), pihole (the hooks rewrite DNS records; the core
    # does nothing) or off (default). group defaults to the service name; pihole_names are informational.
    ROUTE_MODES = %w[ha-routes pihole off].freeze
    ServiceRoutes = Struct.new(:mode, :group, :pihole_names, keyword_init: true) do
      def ha_routes? = mode == "ha-routes"
    end

    # auto_promote: true/false from cluster.yml, nil = the node-wide AUTO_PROMOTE.
    # url: the service's user-facing page (dashboard link); per_host_urls: {host => url} for the
    # per-host rows, defaulting to the health URL's origin.
    Service = Struct.new(:name, :primary, :standby, :health, :hooks_dir, :probe, :auto_promote, :tunables,
                         :routes, :url, :host_urls, keyword_init: true)

    # The parsed cluster.yml plus the identity of this node.
    class Cluster
      attr_reader :node_name, :hosts, :services, :quorum_tcp

      def initialize(doc, node_name:, env: ENV)
        @node_name = node_name
        @hosts = (doc["hosts"] || {}).to_h do |name, h|
          probes = (h["probes"] || {}).to_h { |k, v| [k.to_sym, v] }.freeze
          [name, Host.new(name: name, address: h["address"], sentinel_url: h["sentinel_url"],
                          role: (h["role"] || "member").to_sym, probes: probes).freeze]
        end.freeze
        @services = (doc["services"] || {}).to_h do |name, s|
          [name, Service.new(name: name, primary: s["primary"], standby: s["standby"],
                             health: (s["health"] || {}).freeze,
                             hooks_dir: s["hooks_dir"] || "hooks/#{name}",
                             probe: parse_probe(s["probe"] || {}, env),
                             auto_promote: s.key?("auto_promote") ? s["auto_promote"] == true : nil,
                             tunables: parse_tunables(name, s["tunables"] || {}),
                             routes: parse_routes(name, s["routes"] || {}),
                             url: s["url"]&.to_s,
                             host_urls: parse_host_urls(s["health"] || {}, s["host_urls"] || {})).freeze]
        end.freeze
        @quorum_tcp = (doc["quorum_tcp"] || []).freeze
        raise Error, "node #{node_name.inspect} not in cluster hosts #{@hosts.keys}" unless @hosts.key?(node_name)
      end

      # {host => url} to open that host's instance: the explicit host_urls, else the health URL's
      # origin (scheme://host:port).
      def parse_host_urls(health, explicit)
        health.to_h { |host, url| [host.to_s, (explicit[host.to_s] || origin_of(url)).to_s] }
              .reject { |_, v| v.empty? }.freeze
      end

      def origin_of(url)
        u = URI.parse(url.to_s)
        return nil unless u.scheme && u.host

        default = { "http" => 80, "https" => 443 }[u.scheme]
        "#{u.scheme}://#{u.host}#{u.port && u.port != default ? ":#{u.port}" : ''}"
      rescue URI::InvalidURIError
        nil
      end

      def parse_routes(service, r)
        mode = r.fetch("mode", "off")
        mode = "off" if mode == false # YAML 1.1 reads a bare `off` as false
        mode = mode.to_s
        raise Error, "service #{service}: routes.mode #{mode.inspect} not in #{ROUTE_MODES}" unless ROUTE_MODES.include?(mode)

        ServiceRoutes.new(mode: mode, group: (r["group"] || service).to_s,
                          pihole_names: Array(r["pihole_names"]).map(&:to_s).freeze).freeze
      end

      def parse_probe(p, env)
        user = (p["username_env"] && env[p["username_env"]]).to_s
        user = p["username"].to_s if user.empty?
        pass = (p["password_env"] && env[p["password_env"]]).to_s
        Probe.new(basic: pass.empty? ? nil : [user, pass].freeze,
                  headers: (p["headers"] || {}).transform_values(&:to_s).freeze,
                  resolve: (p["resolve"] || {}).freeze,
                  tls_verify: !%w[false no off 0].include?(p.fetch("tls_verify", true).to_s.downcase)).freeze
      end

      def parse_tunables(service, t)
        t.to_h do |k, v|
          key = k.to_sym
          raise Error, "service #{service}: unknown tunable #{k.inspect}" unless SERVICE_TUNABLES.include?(key)

          [key, Integer(v)]
        end.freeze
      rescue ArgumentError, TypeError => e
        raise Error, "service #{service}: tunables must be integers (#{e.message})"
      end

      def host(name) = @hosts.fetch(name) { raise Error, "unknown host #{name.inspect}" }
      def service(name) = @services.fetch(name) { raise Error, "unknown service #{name.inspect}" }
      def self_host = host(node_name)
      def peers = @hosts.values.reject { |h| h.name == node_name }
      def majority = (@hosts.size / 2) + 1
    end

    module_function

    def fetch(key)
      default = DEFAULTS.fetch(key.to_s) { raise KeyError, "unknown config key #{key.inspect}" }
      raw = ENV[key.to_s]
      return default if raw.nil? || raw.strip.empty?

      cast(raw.strip, default, key)
    end

    def cast(value, default, key)
      case default
      when Integer then Integer(value)
      when Float then Float(value)
      when true, false then %w[1 true yes on].include?(value.downcase)
      else value
      end
    rescue ArgumentError
      $log.warn "[config] #{key}=#{value.inspect} is not a #{default.class}; using default #{default.inspect}"
      default
    end

    def node_name
      name = fetch(:NODE_NAME)
      raise Error, "NODE_NAME is required (one of #{cluster_doc.fetch('hosts', {}).keys.join(' | ')})" if name.empty?

      name
    end

    def cluster
      @cluster ||= Cluster.new(cluster_doc, node_name: node_name)
    end

    def cluster_doc
      file = fetch(:CLUSTER_FILE)
      raise Error, "cluster file #{file.inspect} not found" unless File.file?(file)

      YAML.safe_load_file(file) || {}
    end

    def acting_node?(service)
      service = cluster.service(service) if service.is_a?(String)
      node_name == service.standby
    end

    # Tests change ENV; memoization must not survive that.
    def reset! = @cluster = nil

    def present?(key) = !fetch(key).to_s.empty?
  end
end
