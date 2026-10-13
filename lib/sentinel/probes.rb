# frozen_string_literal: true

require "json"

module Sentinel
  # Fans a host's probes out in parallel (one cycle costs one timeout, not the sum) and folds
  # the results into a HostView. The service mapping is the bash primary_service_status: a 401
  # proves the server is up even when the credential is stale. service_urls is {service => url}
  # for every service the host carries; service_probes is {service => Config::Probe} (credential,
  # headers, per-host ip) — a service without one is probed plain.
  module Probes
    module_function

    def host(host, service_urls: {}, service_probes: {}, timeout:, now: Time.now)
      jobs = {}
      if (ssh_port = host.probes[:ssh])
        jobs[:ssh] = -> { Tcp.open?(host.address, ssh_port, timeout: timeout) }
      end
      if (traefik_port = host.probes[:traefik])
        jobs[:traefik] = -> { Tcp.open?(host.address, traefik_port, timeout: timeout) }
      end
      if host.probes[:icmp]
        jobs[:icmp] = -> { Icmp.up?(host.address, timeout: timeout) }
      end
      service_urls = service_urls || {}
      service_probes = service_probes || {}
      service_urls.each do |service, url|
        probe = service_probes[service]
        jobs[[:service, service]] = lambda do
          service_status(url, basic: probe&.basic, headers: probe&.headers,
                              resolve_ip: probe&.resolve_ip(host.name), timeout: timeout)
        end
      end

      results = Workers.parallel(jobs, timeout: timeout + 1.0)
      HostView.new(
        name: host.name,
        services: service_urls.keys.to_h do |service|
          state = results[[:service, service]]
          [service, state.is_a?(String) ? state : "down"]
        end,
        ssh: jobs.key?(:ssh) ? up_down(results[:ssh]) : nil,
        icmp: jobs.key?(:icmp) ? up_down(results[:icmp]) : nil,
        traefik: jobs.key?(:traefik) ? up_down(results[:traefik]) : nil,
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

    def service_status(url, timeout:, basic: nil, headers: nil, resolve_ip: nil)
      res = Http.get(url, basic: basic, headers: headers, resolve_ip: resolve_ip, timeout: timeout, tls_verify: false)
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
