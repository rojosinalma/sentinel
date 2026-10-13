# frozen_string_literal: true

require "json"

module Sentinel
  # Operator actions shared by the dashboard API and the MCP tools. Transitions run in a
  # background thread (a promote takes ~10 s, a demote up to a minute): the caller gets an
  # immediate answer and follows the outcome through /api/transitions and the events. One
  # transition slot per service: two services may transition at once, one service may not.
  module Actions
    MUTEX = Mutex.new
    @running = {}

    module_function

    # service: nil -> the node-wide hold (every service), else that service's own hold. A
    # per-service hold set on a non-acting node is forwarded to the acting node, where the
    # decider reads it; the node-wide hold stays local (it is this node's own switch).
    def hold!(runtime, on:, who: "api", service: nil)
      if service && !runtime[:loop].acting?(service)
        svc = runtime[:cluster].services[service]
        return [false, "unknown service #{service.inspect}"] unless svc
        return forward!(runtime, svc, "hold", who: who, params: { "on" => on.to_s })
      end
      state = service ? runtime[:state].for(service) : runtime[:state]
      scope = service ? "#{service} hold" : "hold"
      if on
        state.hold_on!(who)
        runtime[:store].event!("hold", "#{scope} set by #{who}", service: service)
      else
        state.hold_off!
        runtime[:store].event!("hold", "#{scope} released by #{who}", service: service)
      end
      [true, "#{scope} #{on ? 'on' : 'off'}"]
    end

    # -> [ok, message]. dry_run runs the hook synchronously (seconds) and returns its tail.
    def transition!(runtime, service_name, hook, args = [], dry_run: false, who: "api")
      return [false, "unknown action #{hook.inspect}"] unless %w[promote demote].include?(hook)

      service = runtime[:cluster].services[service_name]
      return [false, "unknown service #{service_name.inspect}"] unless service

      unless runtime[:loop].acting?(service.name)
        return forward!(runtime, service, hook, dry_run: dry_run, who: who,
                                 params: { "dry_run" => dry_run.to_s, "confirm" => hook, "fast" => args.include?("--fast").to_s,
                                           "force" => args.include?("--force").to_s })
      end
      return [false, "hook #{service.name}/#{hook} missing"] unless runtime[:hooks].exists?(service.name, hook)

      if dry_run
        result = runtime[:hooks].run(service.name, hook, *args, "--dry-run", dry_run: true)
        return [result.exit_code.zero?, "#{hook} --dry-run rc=#{result.exit_code}\n#{result.output_tail.join("\n")}"]
      end

      state = runtime[:state].for(service.name)
      return [false, "a #{service.name} transition is already running (#{state.transition || 'lock held'})"] if state.busy?

      MUTEX.synchronize do
        if @running[service.name]
          return [false, "a #{service.name} transition started via the api is already running (#{@running[service.name]})"]
        end

        @running[service.name] = hook
      end
      runtime[:store].event!("decision", "#{hook} requested by #{who}", service: service.name)
      Workers.safe_thread("api-#{service.name}-#{hook}") do
        runtime[:loop].execute_transition!(service.name, hook, args)
      ensure
        MUTEX.synchronize { @running.delete(service.name) }
      end
      [true, "#{hook} started; follow /api/transitions and the events"]
    end

    # Any node's dashboard or MCP may drive a service: a request landing on a non-acting node is
    # replayed against the acting node's own /api/<action> (its sentinel_url from cluster.yml),
    # tagged with the forwarding node so the audit trail says where it came from.
    def forward!(runtime, service, action, params:, who: "api", dry_run: false)
      host = runtime[:cluster].hosts[service.standby]
      return [false, "acting node #{service.standby} of #{service.name} is not in cluster.yml"] unless host

      url = "#{host.sentinel_url}/api/#{action}"
      body = params.merge("service" => service.name, "who" => "#{who}@#{runtime[:cluster].node_name}")
      timeout = dry_run ? Config.fetch(:FORWARD_TIMEOUT_S) : Config.fetch(:PEER_TIMEOUT_S)
      res = Transport::Http.new(timeout: timeout).post_form(url, body)
      return [false, "forward to #{service.standby} failed: #{res[:error]}"] if res[:error]

      doc = begin
        JSON.parse(res[:body])
      rescue JSON::ParserError
        {}
      end
      ok = res[:code] == 200 && doc["ok"] == true
      [ok, "#{doc['message'] || res[:body].to_s[0, 300]}#{ok ? " (via #{service.standby})" : ''}"]
    end

    # {service => hook} of the api-started transitions in flight.
    def running = MUTEX.synchronize { @running.dup }
  end
end
