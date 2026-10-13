# frozen_string_literal: true

module Sentinel
  # Operator actions shared by the dashboard API and the MCP tools. Transitions run in a
  # background thread (a promote takes ~10 s, a demote up to a minute): the caller gets an
  # immediate answer and follows the outcome through /api/transitions and the events. One
  # transition slot per service: two services may transition at once, one service may not.
  module Actions
    MUTEX = Mutex.new
    @running = {}

    module_function

    # service: nil -> the node-wide hold (every service), else that service's own hold.
    def hold!(runtime, on:, who: "api", service: nil)
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
        return [false, "this node (#{runtime[:cluster].node_name}) is not the acting node " \
                       "of #{service.name} (#{service.standby}); call it there"]
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

    # {service => hook} of the api-started transitions in flight.
    def running = MUTEX.synchronize { @running.dup }
  end
end
