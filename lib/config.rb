# frozen_string_literal: true

# The web layer's own knobs (dashboard, /health); typed defaults overridden by the environment
# (.env via dotenv). The sentinel core's settings live in Sentinel::Config.
module Config
  DEFAULTS = {
    "HOST_NAME"             => "unknown",
    "REFRESH_S"             => 10,
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
