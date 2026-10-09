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
    mode = doc["mode"] || results.dig(:standby_root, :mode, :value)
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
        node-a: { opencode: results[:primary_service], webui: results[:primary_webui] },
        node-b: { opencode: results[:node_b_opencode], webui: results[:node_b_webui] }
      },
      dns: dns,
      standby_root: results[:standby_root]
    }
  end

  def jobs
    sentinel_url = ::Config.fetch("SENTINEL_URL")
    base = {
      sentinel: -> { ::Probes::Sentinel.call(sentinel_url) },
      primary_service: -> { ::Probes::Opencode.call(::Config.fetch("NODE_A_OPENCODE_URL")) },
      primary_webui: -> { ::Probes::Webui.call(::Config.fetch("NODE_A_WEBUI_URL")) },
      node_b_opencode: -> { ::Probes::Opencode.call(::Config.fetch("NODE_B_OPENCODE_URL")) },
      node_b_webui: -> { ::Probes::Webui.call(::Config.fetch("NODE_B_WEBUI_URL")) },
      standby_root: -> { ::Probes::StandbyRoot.call(::Config.fetch("NODE_B_ROOT")) }
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
