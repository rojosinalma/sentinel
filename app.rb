# frozen_string_literal: true

require "json"
require "roda"
require_relative "lib/logger"
require_relative "lib/config"
require_relative "lib/workers"

# Stateful files above load once; everything below reloads in development.
RELOADED = %w[lib/probes/http lib/probes/opencode lib/probes/openchamber lib/probes/sentinel
              lib/probes/dns lib/probes/tiny_root lib/status].freeze
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

  route do |r|
    r.public

    r.get("health") { json_ok("healthy", served_by: ::Config.fetch("HOST_NAME"), version: ::Config.fetch("APP_VERSION")) }

    r.on "api" do
      r.get("status") do
        response["cache-control"] = "no-store"
        ::Status.current
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
