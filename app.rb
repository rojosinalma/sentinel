# frozen_string_literal: true

require "json"
require "roda"
require "mcp"
require_relative "lib/log"
require_relative "lib/config"
require_relative "lib/workers"

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

  # The sentinel runtime (nil on an instance without NODE_NAME).
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

  # The optional ?service= / {service} argument, validated against cluster.yml; nil when absent.
  # "dashboard" for a browser, or the forwarding node's tag (e.g. dashboard@node-a) so the
  # audit trail names the page that asked.
  def who_param(r)
    who = r.params["who"].to_s.strip
    who.match?(/\A[\w.@-]{1,64}\z/) ? who : "dashboard"
  end

  def service_param(r, rt)
    name = r.params["service"].to_s
    return nil if name.empty?

    rt[:cluster].services.key?(name) ? name : halt_json(r, 404, "unknown service #{name.inspect}")
  end

  def halt_json(r, status, message)
    response.status = status
    response["content-type"] = "application/json"
    r.halt response.finish_with_body([JSON.generate(json_err(message))])
  end

  # LEGACY_REDIRECT_FROM/TO: host prefixes; a request whose host starts with FROM is sent
  # (308, path-preserving) to the same host with TO in its place. Off when either is empty.
  def legacy_redirect_target(r)
    from = ::Sentinel::Config.fetch(:LEGACY_REDIRECT_FROM)
    to = ::Sentinel::Config.fetch(:LEGACY_REDIRECT_TO)
    return nil if from.empty? || to.empty?

    host = r.host.to_s
    return nil unless host.start_with?(from)

    "https://#{to}#{host.delete_prefix(from)}#{r.fullpath}"
  end

  route do |r|
    if (target = legacy_redirect_target(r))
      response["location"] = target
      response.status = 308
      r.halt response.finish
    end

    r.public

    r.get("health") { json_ok("healthy", served_by: ::Config.fetch("HOST_NAME"), version: ::Config.fetch("APP_VERSION")) }

    # --- the frozen legacy single-service document (lib/sentinel/status.rb)
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
      # ?service= narrows both to one service; absent = every service (and node-level rows).
      r.get "events" do
        rt = sentinel!(r)
        limit = (r.params["limit"] || 200).to_i.clamp(1, 1000)
        json_ok("events", events: rt[:store].events(limit: limit, kind: r.params["kind"],
                                                    service: service_param(r, rt)))
      end

      r.get "transitions" do
        rt = sentinel!(r)
        limit = (r.params["limit"] || 50).to_i.clamp(1, 200)
        json_ok("transitions", transitions: rt[:store].transitions(limit: limit, service: service_param(r, rt)))
      end

      # The generic, versioned document: every host, every service, neutral names.
      r.get "v1/status" do
        rt = sentinel!(r)
        response["cache-control"] = "no-store"
        ::Sentinel::Status.v1(loop: rt[:loop], state: rt[:state])
      end

      # The dashboard's cluster view: richer than /status, local node's perspective on one
      # service (?service=<name>, default opencode).
      r.get "sentinel" do
        rt = sentinel!(r)
        response["cache-control"] = "no-store"
        name = r.params["service"] || ::Sentinel::Status.legacy_service
        service = rt[:cluster].services[name] or halt_json(r, 404, "unknown service #{name.inspect}")
        doc = rt[:loop].last || {}
        entry = doc.dig(:services, name) || {}
        json_ok("sentinel",
                node: rt[:cluster].node_name,
                acting: rt[:loop].acting?(name),
                service: service.name,
                standby: service.standby,
                services: rt[:cluster].services.keys,
                mode: entry[:mode],
                agreed_class: entry[:agreed_class],
                quorum: doc[:quorum],
                busy: entry[:busy] || false,
                hold: rt[:state].for(name).hold?,
                transition: rt[:state].for(name).transition,
                reachable_peers: doc[:reachable_peers] || [],
                classes: doc.dig(:classes, name) || {},
                hosts: (doc[:views] || {}).transform_values(&:to_h),
                roles: rt[:cluster].hosts.transform_values { |h| h.role.to_s },
                gates: entry[:decider] || {},
                lease: ::Sentinel::Status.lease_public(rt[:store].lease_current(service.name)),
                route_primary: ::Sentinel::Status.route_primary_for(doc, name),
                ha_connectors: doc[:ha_connectors],
                standby_stack: entry[:standby_stack],
                action_running: ::Sentinel::Actions.running,
                checked_at: doc[:at]&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ"))
      end

      # {on, service?}: without service the hold is node-wide (every service this node acts for).
      r.post "hold" do
        rt = sentinel!(r)
        on = %w[1 true yes on].include?(r.params["on"].to_s.downcase)
        service = service_param(r, rt)
        ok, message = ::Sentinel::Actions.hold!(rt, on: on, who: who_param(r), service: service)
        hold = if service && !rt[:loop].acting?(service)
                 on # forwarded: the acting node holds the file; echo what was asked
               else
                 service ? rt[:state].for(service).hold? : rt[:state].hold?
               end
        ok ? json_ok(message, hold: hold, service: service) : json_err(message)
      end

      r.post "promote" do
        rt = sentinel!(r)
        service = r.params["service"] || ::Sentinel::Status.legacy_service
        args = []
        args << "--fast" if r.params["fast"] == "true"
        args << "--force" if r.params["force"] == "true"
        if r.params["dry_run"] == "true"
          ok, message = ::Sentinel::Actions.transition!(rt, service, "promote", args, dry_run: true, who: who_param(r))
        elsif r.params["confirm"] != "promote"
          ok = false
          message = 'confirmation failed: type the word "promote"'
        else
          ok, message = ::Sentinel::Actions.transition!(rt, service, "promote", args, who: who_param(r))
        end
        ok ? json_ok(message) : json_err(message)
      end

      r.post "demote" do
        rt = sentinel!(r)
        service = r.params["service"] || ::Sentinel::Status.legacy_service
        if r.params["dry_run"] == "true"
          ok, message = ::Sentinel::Actions.transition!(rt, service, "demote", [], dry_run: true, who: who_param(r))
        elsif r.params["confirm"] != "demote"
          ok = false
          message = 'confirmation failed: type the word "demote"'
        else
          ok, message = ::Sentinel::Actions.transition!(rt, service, "demote", ["--yes"], who: who_param(r))
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
