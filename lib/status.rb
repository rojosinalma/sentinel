# frozen_string_literal: true

require "time"

# Aggregates every probe into one document. Concurrent callers coalesce: one build runs under the
# mutex and everyone within STATUS_CACHE_S gets the same result, so a page refresh storm costs one
# round of probes, not one per client.
module Status
  MUTEX = Mutex.new
  @cache = nil
  @cached_at = 0.0

  module_function

  def current
    MUTEX.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return @cache if @cache && (now - @cached_at) < ::Config.fetch("STATUS_CACHE_S")

      @cache = build
      @cached_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @cache
    end
  end

  def build
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timeout = ::Config.fetch("PROBE_TIMEOUT_S")
    results = ::Workers.parallel(jobs, timeout: timeout + 1.0)
    sentinel = results[:sentinel]
    doc = sentinel[:doc] || {}
    mode = doc["mode"] || results.dig(:tiny_root, :mode, :value)
    dns = results.slice(*dns_keys).transform_keys { |k| k.to_s.delete_prefix("dns:") }
    dns.each_value { |d| d[:points_to] ||= mode if d[:inferred] }

    {
      ok: true,
      message: "status",
      served_by: ::Config.fetch("HOST_NAME"),
      generated_at: Time.now.utc.iso8601,
      took_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      refresh_s: ::Config.fetch("REFRESH_S"),
      build: { version: ::Config.fetch("APP_VERSION"), built_at: ::Config.fetch("BUILD_TIME") },
      other_instance: { name: ::Config.fetch("OTHER_INSTANCE_NAME"), url: ::Config.fetch("OTHER_INSTANCE_URL") },
      primary: primary(mode, sentinel),
      sentinel: sentinel,
      hosts: {
        silver: { opencode: results[:silver_opencode], openchamber: results[:silver_openchamber] },
        tiny: { opencode: results[:tiny_opencode], openchamber: results[:tiny_openchamber] }
      },
      dns: dns,
      tiny_root: results[:tiny_root]
    }
  end

  def jobs
    sentinel_url = ::Config.fetch("SENTINEL_URL")
    base = {
      sentinel: -> { ::Probes::Sentinel.call(sentinel_url) },
      silver_opencode: -> { ::Probes::Opencode.call(::Config.fetch("SILVER_OPENCODE_URL")) },
      silver_openchamber: -> { ::Probes::Openchamber.call(::Config.fetch("SILVER_OPENCHAMBER_URL")) },
      tiny_opencode: -> { ::Probes::Opencode.call(::Config.fetch("TINY_OPENCODE_URL")) },
      tiny_openchamber: -> { ::Probes::Openchamber.call(::Config.fetch("TINY_OPENCHAMBER_URL")) },
      tiny_root: -> { ::Probes::TinyRoot.call(::Config.fetch("TINY_ROOT")) }
    }
    ::Config.list("DNS_NAMES").each { |name| base[:"dns:#{name}"] = -> { ::Probes::Dns.call(name) } }
    base
  end

  def dns_keys = ::Config.list("DNS_NAMES").map { |n| :"dns:#{n}" }

  def primary(mode, sentinel)
    {
      host: mode || "unknown",
      source: sentinel[:state] == "ok" ? "sentinel" : (mode ? "state/mode" : "none"),
      since: sentinel.dig(:doc, "since")
    }
  end
end
