# frozen_string_literal: true

require "json"
require "roda"
require "mcp"
require_relative "lib/log"
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

  # The sentinel runtime (nil on a plain standby-status instance without NODE_NAME).
  def sentinel
    defined?(::Sentinel) && ::Sentinel.enabled? ? ::Sentinel.runtime : nil
  end

  def sentinel!(r)
    sentinel || begin
      response.status = 503
      r.halt response.finish_with_body([JSON.generate(json_err("sentinel not enabled on this instance (NODE_NAME unset)"))])
    end
  end

  def mcp_authorized!(r)
    token = ENV["SENTINEL_MCP_TOKEN"].to_s
    halt_json(r, 404, "Not found") if token.empty?

    auth = r.env["HTTP_AUTHORIZATION"].to_s
    return if auth.start_with?("Bearer ") && Rack::Utils.secure_compare(auth.delete_prefix("Bearer "), token)

    $log.warn "[auth] unauthorized #{r.request_method} #{r.path} from #{r.ip}"
    halt_json(r, 401, "Unauthorized: missing or invalid bearer token")
  end

  def halt_json(r, status, message)
    response.status = status
    response["content-type"] = "application/json"
    r.halt response.finish_with_body([JSON.generate(json_err(message))])
  end

  route do |r|
    # standby.* -> sentinel.* (the page this app absorbed; permanent, path-preserving)
    if (host = r.host.to_s).start_with?("standby.")
      response["location"] = "https://#{host.sub(/\Astandby\./, 'sentinel.')}#{r.fullpath}"
      response.status = 308
      r.halt response.finish
    end

    r.public

    r.get("health") { json_ok("healthy", served_by: ::Config.fetch("HOST_NAME"), version: ::Config.fetch("APP_VERSION")) }

    # --- sentinel: byte-compatible with the bash sentinel's :4197/status
    r.get "status" do
      rt = sentinel!(r)
      response["content-type"] = "application/json"
      response["cache-control"] = "no-store"
      ::Sentinel::Status.to_json(
        ::Sentinel::Status.build(loop: rt[:loop], state: rt[:state], config: rt[:config])
      )
    end

    r.on "peer" do
      rt = sentinel!(r)

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

    r.on "mcp" do
      sentinel!(r)
      mcp_authorized!(r)

      r.post do
        transport = MCP::Server::Transports::StreamableHTTPTransport.new(
          ::Sentinel::McpServer.build, stateless: true, dns_rebinding_protection: false
        )
        r.halt transport.handle_request(r)
      end

      r.is { halt_json(r, 405, "Stateless endpoint: POST JSON-RPC messages to /mcp") }
    end

    r.on "api" do
      r.get("status") do
        response["cache-control"] = "no-store"
        ::Status.current
      end

      r.get "events" do
        rt = sentinel!(r)
        limit = (r.params["limit"] || 200).to_i.clamp(1, 1000)
        json_ok("events", events: rt[:store].events(limit: limit, kind: r.params["kind"]))
      end

      r.get "transitions" do
        rt = sentinel!(r)
        limit = (r.params["limit"] || 50).to_i.clamp(1, 200)
        json_ok("transitions", transitions: rt[:store].transitions(limit: limit))
      end

      # The dashboard's cluster view: richer than /status, local node's perspective.
      r.get "sentinel" do
        rt = sentinel!(r)
        response["cache-control"] = "no-store"
        doc = rt[:loop].last || {}
        json_ok("sentinel",
                node: rt[:cluster].node_name,
                acting: rt[:loop].acting?,
                service: rt[:service].name,
                standby: rt[:service].standby,
                mode: doc[:mode],
                agreed_class: doc[:agreed_class],
                quorum: doc[:quorum],
                busy: doc[:busy] || false,
                hold: rt[:state].hold?,
                transition: rt[:state].transition,
                reachable_peers: doc[:reachable_peers] || [],
                classes: doc[:classes] || {},
                hosts: (doc[:views] || {}).transform_values(&:to_h),
                roles: rt[:cluster].hosts.transform_values { |h| h.role.to_s },
                gates: doc[:decider] || {},
                lease: rt[:store].lease_current(rt[:service].name),
                route_primary: doc[:route_primary],
                ha_connectors: doc[:ha_connectors],
                tiny_stack: doc[:tiny_stack],
                action_running: ::Sentinel::Actions.running,
                checked_at: doc[:at]&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ"))
      end

      r.post "hold" do
        rt = sentinel!(r)
        on = %w[1 true yes on].include?(r.params["on"].to_s.downcase)
        ok, message = ::Sentinel::Actions.hold!(rt, on: on, who: "dashboard")
        ok ? json_ok(message, hold: rt[:state].hold?) : json_err(message)
      end

      r.post "promote" do
        rt = sentinel!(r)
        args = []
        args << "--fast" if r.params["fast"] == "true"
        args << "--force" if r.params["force"] == "true"
        if r.params["dry_run"] == "true"
          ok, message = ::Sentinel::Actions.transition!(rt, "promote", args, dry_run: true, who: "dashboard")
        elsif r.params["confirm"] != "promote"
          ok = false
          message = 'confirmation failed: type the word "promote"'
        else
          ok, message = ::Sentinel::Actions.transition!(rt, "promote", args, who: "dashboard")
        end
        ok ? json_ok(message) : json_err(message)
      end

      r.post "demote" do
        rt = sentinel!(r)
        if r.params["dry_run"] == "true"
          ok, message = ::Sentinel::Actions.transition!(rt, "demote", [], dry_run: true, who: "dashboard")
        elsif r.params["confirm"] != "demote"
          ok = false
          message = 'confirmation failed: type the word "demote"'
        else
          ok, message = ::Sentinel::Actions.transition!(rt, "demote", ["--yes"], who: "dashboard")
        end
        ok ? json_ok(message) : json_err(message)
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
