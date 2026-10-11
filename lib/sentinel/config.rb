# frozen_string_literal: true

require "yaml"

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
      "STACK_RETRY_S"           => 120,
      "NOTIFY_DOWN_AFTER_S"     => 60,
      "HEARTBEAT_S"             => 300,
      "AUTO_PROMOTE"            => "on",
      "AUTO_FAILBACK"           => "on",
      "TCP_TIMEOUT_S"           => 2,
      "HTTP_TIMEOUT_S"          => 5,
      "PEER_TIMEOUT_S"          => 2,
      "PEER_STALE_S"            => 10,
      "LEASE_TTL_S"             => 30,
      "LEASE_RENEW_S"           => 10,
      "HOOK_TIMEOUT_S"          => 900,
      "STATE_DIR"               => "data/state",
      "LOG_DIR"                 => "data/logs",
      "DB_PATH"                 => "data/sentinel.db",
      "EVENTS_KEEP_DAYS"        => 30,
      "SENTINEL_PORT"           => 4197,
      "OPENCODE_SERVER_USERNAME" => "opencode",
      "OPENCODE_SERVER_PASSWORD" => "",
      "DISCORD_WEBHOOK_URL"     => "",
      "APPRISE_URL"             => "",
      "ROUTE_MODE"              => "ha-routes",
      "HA_ROUTES_BIN"           => "",
      "HA_TUNNEL_ID"            => "",
      "CF_API_TOKEN"            => "",
      "CF_ACCOUNT_ID"           => "",
      "ROUTE_TIMEOUT_S"         => 60,
      "LOG_LEVEL"               => "info"
    }.freeze

    Host = Struct.new(:name, :address, :sentinel_url, :role, :probes, keyword_init: true) do
      def witness? = role == :witness
    end

    Service = Struct.new(:name, :primary, :standby, :health, :hooks_dir, keyword_init: true)

    # The parsed cluster.yml plus the identity of this node.
    class Cluster
      attr_reader :node_name, :hosts, :services, :quorum_tcp

      def initialize(doc, node_name:)
        @node_name = node_name
        @hosts = (doc["hosts"] || {}).to_h do |name, h|
          probes = (h["probes"] || {}).to_h { |k, v| [k.to_sym, v] }.freeze
          [name, Host.new(name: name, address: h["address"], sentinel_url: h["sentinel_url"],
                          role: (h["role"] || "member").to_sym, probes: probes).freeze]
        end.freeze
        @services = (doc["services"] || {}).to_h do |name, s|
          [name, Service.new(name: name, primary: s["primary"], standby: s["standby"],
                             health: (s["health"] || {}).freeze,
                             hooks_dir: s["hooks_dir"] || "hooks/#{name}").freeze]
        end.freeze
        @quorum_tcp = (doc["quorum_tcp"] || []).freeze
        raise Error, "node #{node_name.inspect} not in cluster hosts #{@hosts.keys}" unless @hosts.key?(node_name)
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
      raise Error, "NODE_NAME is required (node-a | node-b | witness-1)" if name.empty?

      name
    end

    def cluster
      @cluster ||= load_cluster
    end

    def load_cluster
      file = fetch(:CLUSTER_FILE)
      raise Error, "cluster file #{file.inspect} not found" unless File.file?(file)

      Cluster.new(YAML.safe_load_file(file) || {}, node_name: node_name)
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
