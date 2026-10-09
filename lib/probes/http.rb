# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

module Probes
  # One bounded GET: both timeouts from PROBE_TIMEOUT_S, optional Basic auth, logged with
  # method/path/outcome at debug. Returns { code:, body:, ms: } or raises nothing — errors come
  # back as { error: }.
  module Http
    module_function

    def get(url, basic: nil, headers: {}, timeout: ::Config.fetch("PROBE_TIMEOUT_S"), tag: "http")
      uri = URI.parse(url)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(*basic) if basic
      headers.each { |k, v| req[k] = v }
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = ::Config.fetch("PROBE_TLS_VERIFY") ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      end
      res = http.start { |h| h.request(req) }
      ms = elapsed_ms(started)
      $log.debug "[#{tag}] GET #{uri} -> #{res.code} (#{ms} ms)"
      { code: res.code.to_i, body: res.body.to_s, ms: ms }
    rescue StandardError => e
      ms = elapsed_ms(started)
      $log.debug "[#{tag}] GET #{url} -> #{e.class}: #{e.message} (#{ms} ms)"
      { error: "#{e.class}: #{e.message}", ms: ms }
    end

    def json(url, **opts)
      res = get(url, **opts)
      return res if res[:error]

      res.merge(json: (JSON.parse(res[:body]) rescue nil))
    end

    def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
end
