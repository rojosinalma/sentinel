# frozen_string_literal: true

module Sentinel
  # Operator actions shared by the dashboard API and the MCP tools. Transitions run in a
  # background thread (a promote takes ~10 s, a demote up to a minute): the caller gets an
  # immediate answer and follows the outcome through /api/transitions and the events.
  module Actions
    MUTEX = Mutex.new
    @running = nil

    module_function

    def hold!(runtime, on:, who: "api")
      state = runtime[:state]
      if on
        state.hold_on!(who)
        runtime[:store].event!("hold", "hold set by #{who}")
      else
        state.hold_off!
        runtime[:store].event!("hold", "hold released by #{who}")
      end
      [true, "hold #{on ? 'on' : 'off'}"]
    end

    # -> [ok, message]. dry_run runs the hook synchronously (seconds) and returns its tail.
    def transition!(runtime, hook, args = [], dry_run: false, who: "api")
      service = runtime[:service]
      return [false, "unknown action #{hook.inspect}"] unless %w[promote demote].include?(hook)

      unless runtime[:loop].acting?
        return [false, "this node (#{runtime[:cluster].node_name}) is not the acting node " \
                       "(#{service.standby}); call it there"]
      end
      return [false, "hook #{service.name}/#{hook} missing"] unless runtime[:hooks].exists?(service.name, hook)

      if dry_run
        result = runtime[:hooks].run(service.name, hook, *args, "--dry-run", dry_run: true)
        return [result.exit_code.zero?, "#{hook} --dry-run rc=#{result.exit_code}\n#{result.output_tail.join("\n")}"]
      end

      return [false, "a transition is already running (#{runtime[:state].transition || 'lock held'})"] if runtime[:state].busy?

      MUTEX.synchronize do
        return [false, "a transition started via the api is already running (#{@running})"] if @running

        @running = hook
      end
      runtime[:store].event!("decision", "#{hook} requested by #{who}", service: service.name)
      Workers.safe_thread("api-#{hook}") do
        runtime[:loop].execute_transition!(hook, args)
      ensure
        MUTEX.synchronize { @running = nil }
      end
      [true, "#{hook} started; follow /api/transitions and the events"]
    end

    def running = MUTEX.synchronize { @running }
  end
end
