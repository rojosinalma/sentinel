# frozen_string_literal: true

require "json"
require "roda"
require_relative "lib/log"
require_relative "lib/config"
require_relative "lib/workers"

# Stateful files above load once; everything below reloads in development.
RELOADED = %w[lib/probes/http lib/probes/opencode lib/probes/webui lib/probes/sentinel
              lib/probes/dns lib/probes/standby_root lib/status].freeze
RELOADED.each do |file|
  defined?(Unreloader) ? Unreloader.require(File.expand_path("#{file}.rb", __dir__)) : require_relative(file)
end

class App < Roda
  plugin :json
  plugin :halt
  plugin :public
  plugin :render, engine: "erb", escape: true, views: File.expand_path("views", __dir__)
  plugin :not_found do
    response["content-type"] = "application/json"
    JSON.generate(json_err("No route for #{request.request_method} #{request.path}"))
  end
  plugin :error_handler do |e|
    $log.error "[app] #{request.request_method} #{request.path}: #{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}"
    response.status = 500
    response["content-type"] = "application/json"
    JSON.generate(json_err("Internal error: #{e.class}: #{e.message}"))
  end

  def json_ok(message, **data) = { ok: true, message: message, **data }
  def json_err(message, **data) = { ok: false, message: message, **data }

  # The sentinel runtime (nil on a plain standby-status instance without NODE_NAME).
  def sentinel
    defined?(::Sentinel) && ::Sentinel.enabled? ? ::Sentinel.runtime : nil
  end

  route do |r|
    r.public

    r.get("health") { json_ok("healthy", served_by: ::Config.fetch("HOST_NAME"), version: ::Config.fetch("APP_VERSION")) }

    # --- sentinel: byte-compatible with the bash sentinel's :4197/status
    r.get "status" do
      rt = sentinel
      unless rt
        response.status = 503
        next json_err("sentinel not enabled on this instance (NODE_NAME unset)")
      end
      response["content-type"] = "application/json"
      response["cache-control"] = "no-store"
      ::Sentinel::Status.to_json(
        ::Sentinel::Status.build(loop: rt[:loop], state: rt[:state], config: rt[:config])
      )
    end

    r.on "peer" do
      rt = sentinel
      unless rt
        response.status = 503
        next json_err("sentinel not enabled on this instance (NODE_NAME unset)")
      end

      r.get "view" do
        response["content-type"] = "application/json"
        response["cache-control"] = "no-store"
        JSON.generate(rt[:loop].peer_view || {})
      end

      r.post "lease" do
        status, body = rt[:lease].handle_request(JSON.parse(r.body.read))
        response.status = status
        body
      rescue JSON::ParserError
        response.status = 400
        json_err("invalid JSON body")
      end

      r.post "lease/release" do
        status, body = rt[:lease].handle_release(JSON.parse(r.body.read))
        response.status = status
        body
      rescue JSON::ParserError
        response.status = 400
        json_err("invalid JSON body")
      end
    end

    r.on "api" do
      r.get("status") do
        response["cache-control"] = "no-store"
        ::Status.current
      end

      r.get "events" do
        rt = sentinel
        unless rt
          response.status = 503
          next json_err("sentinel not enabled on this instance (NODE_NAME unset)")
        end
        limit = (r.params["limit"] || 200).to_i.clamp(1, 1000)
        json_ok("events", events: rt[:store].events(limit: limit, kind: r.params["kind"]))
      end
    end

    r.root do
      @host = ::Config.fetch("HOST_NAME")
      @refresh_s = ::Config.fetch("REFRESH_S")
      @version = ::Config.fetch("APP_VERSION")
      @built_at = ::Config.fetch("BUILD_TIME")
      @other_name = ::Config.fetch("OTHER_INSTANCE_NAME")
      @other_url = ::Config.fetch("OTHER_INSTANCE_URL")
      view "index"
    end
  end
end
