# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Sentinel
  # Who the public hostnames reach (ha-routes get) and how many connectors the shared tunnel
  # has (one CF API read). Both are bounded and best-effort: an unknown answer is "unknown"/nil,
  # never an exception. The loop refreshes these at the host-health cadence, on the acting node
  # only (that is where the CF credential lives).
  #
  # Routes are per group (`ha-routes … --group <name>`, one group per service); an ha-routes
  # that predates groups (its --help has no --group) gets the group-less calls, which act on its
  # single default group.
  module Routes
    module_function

    GROUP_FLAG = "--group"

    # -> a host name from `hosts` | "mixed" | "none" | "unknown" | "n/a" (route_mode off)
    # hosts: the names a primary may be (cluster.yml hosts); nil accepts any single token.
    def primary_current(bin:, timeout:, route_mode: "ha-routes", group: nil, hosts: nil)
      return "n/a" unless route_mode == "ha-routes"
      return "unknown" unless usable?(bin)

      out = capture(bin, "get", *group_args(bin, group, timeout: timeout), timeout: timeout)
      return "unknown" if out.nil? || out.empty?
      return out if hosts&.include?(out)

      out[0, 40]
    end

    # -> "ok" | "failed" | "skipped"; `ha-routes set <target> [--group g]` is idempotent.
    def set_primary(target, bin:, timeout:, route_mode: "ha-routes", group: nil)
      return "skipped" unless route_mode == "ha-routes"
      return "skipped" unless usable?(bin)

      capture(bin, "set", target, *group_args(bin, group, timeout: timeout), timeout: timeout) ? "ok" : "failed"
    end

    # Does this ha-routes know --group? Decided from its --help text (no credentials, no API
    # call), cached per binary path + mtime so a synced-in newer copy is picked up.
    def supports_groups?(bin, timeout:)
      return false unless usable?(bin)

      key = [File.expand_path(bin), File.mtime(bin).to_f]
      @group_support ||= {}
      @group_support.fetch(key) do
        @group_support.clear if @group_support.size > 16
        @group_support[key] = capture(bin, "--help", timeout: timeout).to_s.include?(GROUP_FLAG)
      end
    end

    def group_args(bin, group, timeout:)
      return [] if blank?(group)
      return [] unless supports_groups?(bin, timeout: timeout)

      [GROUP_FLAG, group]
    end

    def reset! = @group_support = nil

    # Distinct connectors registered on the ha-tunnel, or nil when it cannot be known.
    # Tunnel id from HA_TUNNEL_ID, else the env file ROUTES_ENV_FILE names, else (legacy) the
    # routes.env two levels above the ha-routes binary.
    def connectors_current(bin:, timeout:, tunnel_id: ENV["HA_TUNNEL_ID"],
                           token: ENV["CF_API_TOKEN"], account_id: ENV["CF_ACCOUNT_ID"],
                           env_file: ENV["ROUTES_ENV_FILE"])
      tunnel_id = routes_env_tunnel_id(bin, env_file: env_file) if blank?(tunnel_id)
      return nil if blank?(tunnel_id) || blank?(token) || blank?(account_id)

      uri = URI("https://api.cloudflare.com/client/v4/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = timeout
      http.read_timeout = timeout
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{token}"
      body = JSON.parse(http.start { |h| h.request(req) }.body)
      return nil unless body["success"]

      Array(body.dig("result", "connections")).map { |c| c["client_id"] }.uniq.size
    rescue StandardError => e
      $log.warn "[routes] connector count failed: #{e.class}: #{e.message}"
      nil
    end

    def routes_env_tunnel_id(bin, env_file: nil)
      file = blank?(env_file) ? (blank?(bin) ? nil : File.expand_path("../../routes.env", bin)) : env_file
      return nil unless file && File.readable?(file)

      File.foreach(file, chomp: true) do |line|
        return Regexp.last_match(1).strip if line =~ /\AHA_TUNNEL_ID=(.+)\z/
      end
      nil
    end

    # Bounded subprocess: stdout on success, nil on failure or timeout.
    def capture(*cmd, timeout:)
      r, w = IO.pipe
      pid = Process.spawn(*cmd, out: w, err: File::NULL)
      w.close
      waiter = Process.detach(pid)
      unless waiter.join(timeout)
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join(2)
        r.close
        return nil
      end
      out = r.read.to_s.strip
      r.close
      waiter.value.success? ? out : nil
    rescue SystemCallError => e
      $log.warn "[routes] #{cmd.first}: #{e.class}: #{e.message}"
      nil
    end

    def usable?(bin) = !blank?(bin) && File.executable?(bin)

    def blank?(value) = value.nil? || value.strip.empty?
  end
end
