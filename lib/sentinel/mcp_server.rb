# frozen_string_literal: true

require "json"
require "mcp"

module Sentinel
  # MCP tools over the same runtime the dashboard uses (pattern: cloche's lib/mcp_server.rb).
  # Mounted at POST /mcp behind the SENTINEL_MCP_TOKEN bearer; stateless.
  module McpServer
    TOOLS = []

    module_function

    def runtime
      Sentinel.runtime or raise "sentinel not enabled on this instance"
    end

    def text(data)
      MCP::Tool::Response.new([{ type: "text", text: data.is_a?(String) ? data : JSON.pretty_generate(data) }])
    end

    def register(name, desc, schema, &handler)
      klass = Class.new(MCP::Tool) do
        tool_name name
        description desc
        input_schema(**schema)
        define_singleton_method(:call) do |server_context: nil, **args|
          McpServer.run_tool(name, args, handler)
        end
      end
      TOOLS << klass
    end

    def run_tool(name, args, handler)
      $log.info "[mcp] tool=#{name} args=#{args.to_json}"
      handler.call(args)
    rescue StandardError => e
      $log.error "[mcp] tool=#{name} failed: #{e.class}: #{e.message}"
      text("Error: #{e.message}")
    end

    def build
      MCP::Server.new(
        name: "sentinel",
        title: "sentinel",
        version: "1.0.0",
        instructions: "The homelab's HA decision layer: one sentinel per host (silver, tiny, " \
                      "witness-1 witness) agreeing on who is primary by majority. status shows this " \
                      "node's view (byte-compatible with the bash sentinel's /status); events and " \
                      "the transitions inside it are the SQLite audit trail. hold blocks automatic " \
                      "failback; promote/demote run the service hooks under a majority lease and " \
                      "only work on the acting node of the service (its standby). Both are destructive: " \
                      "pass confirm with the action name, or dry_run true to see the plan. Every " \
                      "service-scoped tool takes an optional service (default opencode).",
        tools: TOOLS
      )
    end

    register "status",
             "This node's sentinel status: mode (who is primary), probe/classification state, " \
             "quorum, gates, routes. The same document consumers read from /status.",
             { properties: {}, required: [] } do
      rt = runtime
      text(Status.build(loop: rt[:loop], state: rt[:state], config: rt[:config]))
    end

    SERVICE_ARG = { type: "string", description: "Service name from cluster.yml (default opencode)" }.freeze

    def service_arg(args) = (args[:service] || Status::LEGACY_SERVICE).to_s

    register "cluster",
             "The cluster view for one service: every host's probes and agreed class, reachable " \
             "peers, quorum, current lease, last transitions. Lists every configured service.",
             { properties: { service: SERVICE_ARG }, required: [] } do |args|
      rt = runtime
      name = service_arg(args)
      service = rt[:cluster].services[name] or raise ArgumentError, "unknown service #{name.inspect}"
      doc = rt[:loop].last || {}
      entry = doc.dig(:services, name) || {}
      text({
             node: rt[:cluster].node_name, service: name, services: rt[:cluster].services.keys,
             acting: rt[:loop].acting?(name), mode: entry[:mode],
             agreed_class: entry[:agreed_class], quorum: doc[:quorum],
             reachable_peers: doc[:reachable_peers], classes: doc.dig(:classes, name),
             hosts: (doc[:views] || {}).transform_values(&:to_h),
             lease: rt[:store].lease_current(service.name),
             hold: rt[:state].hold?, transition: rt[:state].transition,
             transitions: rt[:store].transitions(service: name, limit: 5)
           })
    end

    register "events",
             "The event log, newest first: probes, classification changes, decisions, gates, " \
             "lease grants/denies, transitions, notifications.",
             { properties: {
                 limit: { type: "integer", description: "Max rows (default 50, cap 500)" },
                 kind: { type: "string", description: "Filter by kind, e.g. decision, lease.deny, transition.end" }
               }, required: [] } do |args|
      limit = (args[:limit] || 50).clamp(1, 500)
      text(runtime[:store].events(limit: limit, kind: args[:kind]))
    end

    register "hold",
             "Query or set the failback hold. With no argument reports the current state; " \
             "on=true blocks automatic failback until released.",
             { properties: {
                 on: { type: "boolean", description: "true = block automatic failback, false = release" }
               }, required: [] } do |args|
      rt = runtime
      if args.key?(:on)
        Actions.hold!(rt, on: args[:on], who: "mcp")
      end
      text({ hold: rt[:state].hold? })
    end

    register "promote",
             "Make the standby primary by running the service's promote hook under a majority " \
             "lease. Destructive: requires confirm=\"promote\" (or dry_run). Only works on the " \
             "acting node. Runs in the background; follow it with events.",
             { properties: {
                 service: SERVICE_ARG,
                 confirm: { type: "string", description: "Must be the word \"promote\"" },
                 dry_run: { type: "boolean", description: "Print the plan, change nothing" },
                 fast: { type: "boolean", description: "Skip the ssh fence (host confirmed dead)" },
                 force: { type: "boolean", description: "Re-run the stack steps when already promoted" }
               }, required: [] } do |args|
      args_list = []
      args_list << "--fast" if args[:fast]
      args_list << "--force" if args[:force]
      if args[:dry_run]
        ok, message = Actions.transition!(runtime, service_arg(args), "promote", args_list, dry_run: true, who: "mcp")
      elsif args[:confirm] != "promote"
        ok = false
        message = 'refused: pass confirm="promote" (or dry_run=true)'
      else
        ok, message = Actions.transition!(runtime, service_arg(args), "promote", args_list, who: "mcp")
      end
      text({ ok: ok, message: message })
    end

    register "demote",
             "Hand the primary back by running the demote hook under a majority lease. " \
             "Destructive: requires confirm=\"demote\" (or dry_run). Only works on the acting node.",
             { properties: {
                 service: SERVICE_ARG,
                 confirm: { type: "string", description: "Must be the word \"demote\"" },
                 dry_run: { type: "boolean", description: "Print the plan, change nothing" }
               }, required: [] } do |args|
      if args[:dry_run]
        ok, message = Actions.transition!(runtime, service_arg(args), "demote", [], dry_run: true, who: "mcp")
      elsif args[:confirm] != "demote"
        ok = false
        message = 'refused: pass confirm="demote" (or dry_run=true)'
      else
        ok, message = Actions.transition!(runtime, service_arg(args), "demote", ["--yes"], who: "mcp")
      end
      text({ ok: ok, message: message })
    end

    TOOLS.freeze
  end
end
