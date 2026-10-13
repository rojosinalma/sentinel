# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Sentinel
  # The peer-to-peer wire. Http talks to real sentinels; InProcess wires several instances
  # together inside one test process.
  module Transport
    class Http
      def initialize(timeout:)
        @timeout = timeout
      end

      def get(url)
        request(url) { |uri| Net::HTTP::Get.new(uri) }
      end

      def post(url, json_hash)
        request(url) do |uri|
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(json_hash)
          req
        end
      end

      # application/x-www-form-urlencoded, the shape the dashboard API routes read.
      def post_form(url, fields)
        request(url) do |uri|
          req = Net::HTTP::Post.new(uri)
          req.set_form_data(fields)
          req
        end
      end

      private

      def request(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
        http.use_ssl = uri.scheme == "https"
        res = http.start { |h| h.request(yield(uri)) }
        { code: res.code.to_i, body: res.body.to_s }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end
    end

    class InProcess
      # apps: {"http://node:4197" => callable(method, path, body_hash_or_nil) -> [code, body_string]}
      def initialize(apps)
        @apps = apps
      end

      def get(url) = dispatch("GET", url, nil)
      def post(url, json_hash) = dispatch("POST", url, json_hash)

      private

      def dispatch(method, url, body)
        prefix = @apps.keys.select { |k| url.start_with?(k) }.max_by(&:length)
        return { error: "no route for #{url}" } unless prefix

        code, response = @apps[prefix].call(method, url.delete_prefix(prefix), body)
        { code: code, body: response }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
