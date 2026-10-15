# frozen_string_literal: true

require "json"

module Sentinel
  # Fans a host's probes out in parallel (one cycle costs one timeout, not the sum) and folds
  # the results into a HostView. Service mapping: 200 with a JSON "version" -> "up <version>",
  # 401 -> "up auth?" (the server answers even when the credential is stale), else "down". service_urls is {service => url}
  # for every service the host carries; service_probes is {service => Config::Probe} (credential,
  # headers, per-host ip, tls_verify) — a service without one is probed plain.
  module Probes
    module_function

    def host(host, service_urls: {}, service_probes: {}, timeout:, service_timeouts: {}, now: Time.now)
      jobs = {}
      if (ssh_port = host.probes[:ssh])
        jobs[:ssh] = -> { Tcp.open?(host.address, ssh_port, timeout: timeout) }
      end
      # https: a TCP open on the host's web port
      if (https_port = host.probes[:https])
        jobs[:https] = -> { Tcp.open?(host.address, https_port, timeout: timeout) }
      end
      if host.probes[:icmp]
        jobs[:icmp] = -> { Icmp.up?(host.address, timeout: timeout) }
      end
      service_urls = service_urls || {}
      service_probes = service_probes || {}
      service_timeouts = service_timeouts || {}
      service_urls.each do |service, url|
        probe = service_probes[service]
        svc_timeout = service_timeouts[service] || timeout
        jobs[[:service, service]] = lambda do
          service_status(url, basic: probe&.basic, headers: probe&.headers,
                              resolve_ip: probe&.resolve_ip(host.name), timeout: svc_timeout,
                              tls_verify: probe.nil? || probe.tls_verify != false)
        end
      end

      deadline = [timeout, *service_timeouts.values].max
      results = Workers.parallel(jobs, timeout: deadline + 1.0)
      HostView.new(
        name: host.name,
        services: service_urls.keys.to_h do |service|
          state = results[[:service, service]]
          [service, state.is_a?(String) ? state : "down"]
        end,
        ssh: jobs.key?(:ssh) ? up_down(results[:ssh]) : nil,
        icmp: jobs.key?(:icmp) ? up_down(results[:icmp]) : nil,
        https: jobs.key?(:https) ? up_down(results[:https]) : nil,
        probed_at: now
      ).freeze
    end

    # "up" if ANY quorum target answers: the probing node can see the LAN itself.
    def quorum(targets, timeout:)
      return "n/a" if targets.nil? || targets.empty?

      jobs = targets.to_h do |target|
        host, port = target.split(":")
        [target, -> { Tcp.open?(host, Integer(port), timeout: timeout) }]
      end
      Workers.parallel(jobs, timeout: timeout + 1.0).values.any? { |v| v == true } ? "up" : "down"
    end

    def service_status(url, timeout:, basic: nil, headers: nil, resolve_ip: nil, tls_verify: true)
      res = Http.get(url, basic: basic, headers: headers, resolve_ip: resolve_ip, timeout: timeout, tls_verify: tls_verify)
      case res[:code]
      when 200
        version = JSON.parse(res[:body])["version"] rescue nil
        "up #{version || '?'}"
      when 401 then "up auth?"
      else "down"
      end
    end

    def up_down(result) = result == true ? "up" : "down"
  end
end
