# frozen_string_literal: true

# Every tunable has a typed default here and is overridden by the environment (.env via dotenv).
# There is no database: the app is stateless so it can run on either host with nothing but .env.
module Config
  DEFAULTS = {
    "HOST_NAME"             => "unknown",
    "SENTINEL_URL"          => "",
    "NODE_A_OPENCODE_URL"   => "",
    "NODE_A_WEBUI_URL" => "",
    "NODE_B_OPENCODE_URL"     => "",
    "NODE_B_WEBUI_URL"  => "",
    "NODE_B_ROOT"             => "",
    "OPENCODE_SERVER_USERNAME" => "opencode",
    "OPENCODE_SERVER_PASSWORD" => "",
    "PROBE_TIMEOUT_S"       => 3.0,
    "PROBE_TLS_VERIFY"      => true,
    "REFRESH_S"             => 10,
    "STATUS_CACHE_S"        => 2.0,
    "LOG_TAIL_LINES"        => 20,
    "DOH_URL"               => "https://cloudflare-dns.com/dns-query",
    "DNS_NAMES"             => "webui.example.com,opencode.example.com",
    "NODE_A_TUNNEL_ID"      => "",
    "NODE_B_TUNNEL_ID"        => "",
    "OTHER_INSTANCE_URL"    => "",
    "OTHER_INSTANCE_NAME"   => "",
    "APP_VERSION"           => "dev",
    "BUILD_TIME"            => ""
  }.freeze

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

  def list(key) = fetch(key).split(",").map(&:strip).reject(&:empty?)
  def present?(key) = !fetch(key).to_s.empty?
end
