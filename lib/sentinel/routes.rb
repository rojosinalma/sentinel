# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Sentinel
  # Who the public hostnames reach (ha-routes get) and how many connectors the shared tunnel
  # has (one CF API read). Both are bounded and best-effort: an unknown answer is "unknown"/nil,
  # never an exception. The bash sentinel refreshed these at the host-health cadence; the loop
  # does the same, on the acting node only (that is where the CF credential lives).
  module Routes
    module_function

    # -> "silver" | "tiny" | "unknown" | "n/a" (route_mode off)
    def primary_current(bin:, timeout:, route_mode: "ha-routes")
      return "n/a" unless route_mode == "ha-routes"
      return "unknown" unless bin && !bin.empty? && File.executable?(bin)

      out = capture(bin, "get", timeout: timeout)
      case out
      when "silver", "tiny" then out
      when nil, "" then "unknown"
      else out[0, 40]
      end
    end

    # -> "ok" | "failed" | "skipped"; `ha-routes set <target>` is idempotent.
    def set_primary(target, bin:, timeout:, route_mode: "ha-routes")
      return "skipped" unless route_mode == "ha-routes"
      return "skipped" unless bin && !bin.empty? && File.executable?(bin)

      capture(bin, "set", target, timeout: timeout) ? "ok" : "failed"
    end

    # Distinct connectors registered on the ha-tunnel, or nil when it cannot be known.
    # Tunnel id from HA_TUNNEL_ID or the routes.env next to the ha-routes binary (bash parity).
    def connectors_current(bin:, timeout:, tunnel_id: ENV["HA_TUNNEL_ID"],
                           token: ENV["CF_API_TOKEN"], account_id: ENV["CF_ACCOUNT_ID"])
      tunnel_id = routes_env_tunnel_id(bin) if blank?(tunnel_id)
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

    def routes_env_tunnel_id(bin)
      return nil if blank?(bin)

      file = File.expand_path("../../routes.env", bin)
      return nil unless File.readable?(file)

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

    def blank?(value) = value.nil? || value.strip.empty?
  end
end
