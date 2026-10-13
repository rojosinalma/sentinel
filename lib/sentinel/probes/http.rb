# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Sentinel
  module Probes
    # One bounded GET. Returns { code:, body:, ms: } or { error: "Class: msg", ms: }; never raises.
    # resolve_ip connects to that address while the Host header and TLS SNI stay the URL's host
    # (curl --resolve), for one hostname that lives on several hosts.
    module Http
      module_function

      def get(url, basic: nil, headers: nil, resolve_ip: nil, timeout:, tls_verify: true)
        uri = URI.parse(url)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        req = Net::HTTP::Get.new(uri)
        req.basic_auth(*basic) if basic
        req["Accept"] = "application/json"
        headers&.each { |k, v| req[k] = v }
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = resolve_ip if resolve_ip
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = tls_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        end
        res = http.start { |h| h.request(req) }
        { code: res.code.to_i, body: res.body.to_s, ms: elapsed_ms(started) }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}", ms: elapsed_ms(started) }
      end

      def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end
