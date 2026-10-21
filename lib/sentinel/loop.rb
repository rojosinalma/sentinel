# frozen_string_literal: true

require "time"

module Sentinel
  # The cycle: probe -> classify -> gossip -> agree -> decide -> act, for every service in
  # cluster.yml. One instance per process; start! runs it in a bounded background thread at
  # POLL_INTERVAL_S. Hosts are probed once per cycle (all their services' health URLs in one
  # fan-out); each service then gets its own classification, agreement, Decider step and
  # dispatch. Only a service's acting node (its standby) ever dispatches for it, and only under
  # a majority lease, so one node can act for one service and merely observe another.
  #
  # config keys (symbols): poll_interval_s, tcp_timeout_s, http_timeout_s, host_health_interval_s,
  # heartbeat_s, lease_renew_s, auto_promote, auto_failback, events_keep_days, route_mode,
  # ha_routes_bin, route_timeout_s. A service's cluster.yml `auto_promote` wins over the node's.
  #
  # Node state is per service (State#for): each service has its own mode, lock, transition and
  # markers under STATE_DIR/<service>/, so one service's transition never touches another's.
  class Loop
    PRUNE_INTERVAL_S = 86_400

    def initialize(config:, cluster:, store:, state:, probes:, gossip:, lease:, hooks:, deciders:,
                   notifier:, routes: Routes, now: -> { Time.now })
      @config = config
      @cluster = cluster
      @store = store
      @state = state
      @probes = probes
      @gossip = gossip
      @lease = lease
      @hooks = hooks
      @notifier = notifier
      @routes = routes
      @now = now
      @services = cluster.services
      raise ArgumentError, "no service configured" if @services.empty?

      @deciders = @services.keys.to_h do |name|
        [name, deciders.fetch(name) { raise ArgumentError, "no decider for service #{name}" }]
      end
      @svc = @services.keys.to_h do |name|
        [name, { host_health: nil, last_health_probe: nil, prev_agreed: nil }]
      end
      @mutex = Mutex.new
      @last = nil
      @peer_view = nil
      @stop = false
      @last_heartbeat = nil
      @route_primary = {}
      @ha_connectors = nil
      @last_route_probe = nil
      @last_prune = nil
    end

    attr_reader :services

    def node_name = @cluster.node_name

    def acting?(service_name) = @cluster.node_name == @services.fetch(service_name).standby

    def acting_services = @services.keys.select { |name| acting?(name) }

    # What a node that does not act for a service knows about its primary: the acting node's
    # gossip view (newest primary_at wins, with that node's per-service transition), then the
    # store's last agreed primary, then the configured primary. Only the acting node writes
    # the service's state files, so /status on every other node reads this instead
    # (a drill showed the primary host's guard reading its own name as the mode throughout the
    # standby's promote).
    def replicated_primary(service)
      if (ps = @gossip.primary_state(service.name))
        { mode: ps[:host], since: ps[:at], transition: ps[:transition] }
      else
        { mode: @store.get("primary.#{service.name}") || service.primary, since: nil, transition: nil }
      end
    end

    def last = @mutex.synchronize { @last }

    # The document /peer/view serves: the last cycle's view with the live state of every
    # service this node acts for laid over it, read at request time. A transition hook runs
    # inside the cycle and may take minutes, so the cycle snapshot alone is frozen at the
    # pre-hook primary for that long (in one failback the standby kept publishing itself as
    # primary after the demote hook had handed the mode back, the primary host's /status
    # followed the gossip, its guard refused the start, the hook timed out and rolled back).
    # primary_at is the newer of the store's agreed value and the mode file's mtime, so the
    # hook's write wins the newest-at rule in Gossip#primary_state at once. Same keys as the
    # cycle view; a service without a mode file keeps the cycle values.
    def peer_view
      doc = @mutex.synchronize { @peer_view }
      doc && live_view(doc)
    end

    def start!
      @stop = false
      @thread = Workers.safe_thread("loop") do
        until @stop
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            cycle!
          rescue StandardError => e
            $log.error "[loop] cycle failed: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}"
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          sleep [@config[:poll_interval_s] - elapsed, 0].max unless @stop
        end
      end
      nil
    end

    def stop!
      @stop = true
      @thread&.join(@config[:poll_interval_s] * 2)
      nil
    end

    def cycle!
      now = @now.call

      # 1+2: probe every host in parallel, classify every service on every host locally (the
      # standby label needs the current mode, so gossip is polled first)
      views = probe_all(now)
      tcp_quorum = @probes.quorum(@cluster.quorum_tcp, timeout: @config[:tcp_timeout_s])
      @gossip.poll!
      modes = @services.to_h { |name, service| [name, current_mode(service)] }
      classes = @services.to_h do |name, service|
        [name, views.to_h { |host, view| [host, classify_host(service, host, view, tcp_quorum, modes[name])] }]
      end

      # 3+4: agreement
      quorum = @gossip.quorum? && tcp_quorum != "down" ? "up" : "down"
      busy_by = @services.keys.to_h { |name| [name, @state.for(name).busy?] }

      # 5-7: per service, who is primary and what to do (acting node only); a hook holding the
      # service's promote.lock means observe only for that service
      refresh_routes(now) if busy_by.values.none? && !acting_services.empty?
      reassert_routes(views, modes) if busy_by.values.none?
      entries = {}
      actions = {}
      @services.each do |name, service|
        agreed = @gossip.agreed_class(name, service.primary, classes[name][service.primary])
        mode = modes[name]
        busy = busy_by[name]
        entries[name] = entry(service, mode: mode, agreed: agreed, busy: busy, now: now)
        next if busy

        record_class_change(service, agreed, mode)
        next unless acting?(name)

        refresh_host_health(service, now, mode, views)
        result = @deciders[name].step(
          now: now, mode: mode, agreed_class: agreed, quorum: quorum,
          host_health: @svc[name][:host_health],
          auto_promote: @deciders[name].config.fetch(:auto_promote, @config[:auto_promote]),
          auto_failback: @config[:auto_failback], probes_str: probes_str(views[service.primary]),
          version: views[service.primary]&.version(name)
        )
        result.log.each { |line| $log.info "[loop] #{name}: #{line}" }
        result.notify.each { |(title, body, type)| notify(title, body, type) }
        entries[name] = entry(service, mode: mode, agreed: agreed, busy: busy, now: now)
        actions[name] = result.action
      end

      # publish before acting: a long hook must not leave stale state behind
      publish(now, views: views, classes: classes, entries: entries, quorum: quorum)
      return last if busy_by.values.all?

      # 8: act, then re-read the mode a hook may have moved
      actions.each do |name, action|
        next if action == :none

        service = @services[name]
        dispatch(service, action)
        entries[name] = entry(service, mode: current_mode(service), agreed: entries[name][:agreed_class],
                                       busy: false, now: now)
      end
      publish(now, views: views, classes: classes, entries: entries, quorum: quorum) unless actions.values.all?(:none)

      # 9+10: heartbeat, housekeeping
      heartbeat(now, entries, quorum)
      prune_if_due(now)
      last
    end

    private

    # ---------------------------------------------------------------- probing

    def probe_all(now)
      timeout = @config[:tcp_timeout_s]
      jobs = @cluster.hosts.values.to_h do |host|
        carried = @services.select { |_, s| s.health[host.name] }
        urls = carried.transform_values { |s| s.health[host.name] }
        probes = carried.transform_values(&:probe)
        # A service may need a laxer probe than the node-wide TCP timeout (cluster.yml
        # tunables.probe_timeout_s): a loaded service that answers its health URL in >3 s
        # would otherwise be classified degraded for as long as the load lasts.
        timeouts = carried.transform_values { |s| s.tunables[:probe_timeout_s] || timeout }
        [host.name, lambda do
          @probes.host(host, service_urls: urls, service_probes: probes,
                             service_timeouts: timeouts, timeout: timeout, now: now)
        end]
      end
      deadline = [@config[:http_timeout_s],
                  *@services.values.map { |s| s.tunables[:probe_timeout_s] }.compact].max
      Workers.parallel(jobs, timeout: deadline + 1.0).to_h do |name, view|
        view = HostView.new(name: name, probed_at: now).freeze unless view.is_a?(HostView)
        [name, view]
      end
    end

    # The bash classifier is service-centric and applies to hosts that carry the service; a
    # host without one (witness) is judged on reachability alone. The standby of a service whose
    # primary is in charge is expected to have the service stopped, so it is `standby`, not
    # degraded; the primary host itself is never relabelled (the decider reads its class).
    def classify_host(service, host_name, view, quorum, mode)
      if service.health.key?(host_name)
        standing_by = host_name == service.standby && mode != service.standby
        return Classifier.classify(view.service_state(service.name), view, quorum: quorum, standing_by: standing_by)
      end
      return :ok if view.any_host_probe_up?

      quorum == "up" ? :dead : :isolated
    end

    # ---------------------------------------------------------------- mode / health

    def current_mode(service)
      if acting?(service.name)
        @state.for(service.name).mode(default: service.primary)
      else
        replicated_primary(service)[:mode]
      end
    end

    # While promoted, the primary host's deeper health (ssh + systemd + docker in the service's
    # health hook) is probed at its own cadence; between probes the last answer stands.
    def refresh_host_health(service, now, mode, views)
      s = @svc[service.name]
      if mode == service.primary
        s[:host_health] = nil
        s[:last_health_probe] = nil
        return
      end

      ssh = views[service.primary]&.ssh
      if ssh != "up"
        s[:host_health] = "down ssh-port"
        s[:last_health_probe] = nil
        return
      end

      due = s[:last_health_probe].nil? || (now - s[:last_health_probe]) >= @config[:host_health_interval_s] ||
            s[:host_health].nil? || s[:host_health] == "down ssh-port"
      return unless due

      s[:last_health_probe] = now
      s[:host_health] =
        if @hooks.exists?(service.name, "health")
          parse_health(@hooks.health(service.name))
        else
          "up"
        end
    end

    # The health hook prints "up" or "down <reason>" as its last line.
    def parse_health(result)
      line = result.output_tail.reverse.find { |l| l == "up" || l.start_with?("down") }
      line || (result.exit_code.zero? ? "up" : "down health-hook")
    end

    # route_primary (per service: `ha-routes get --group <group>`) / ha_connectors at the
    # host-health cadence, bash refresh_route_primary. Only services this node acts for and whose
    # routes.mode is ha-routes are asked; pihole/off services report "n/a".
    def refresh_routes(now)
      return if @last_route_probe && (now - @last_route_probe) < @config[:host_health_interval_s]

      @last_route_probe = now
      hosts = @cluster.hosts.keys
      @route_primary = acting_services.to_h do |name|
        routes = @services[name].routes
        [name, @routes.primary_current(bin: @config[:ha_routes_bin], timeout: @config[:route_timeout_s],
                                       route_mode: routes.ha_routes? ? @config[:route_mode] : "off",
                                       group: routes.group, hosts: hosts)]
      end
      @ha_connectors = @routes.connectors_current(bin: @config[:ha_routes_bin],
                                                  timeout: @config[:http_timeout_s])
    end

    # Keep the public routes on the mode host (bash re-asserted them every fence cycle; under
    # HOOK_ROUTE_MODE=core the hooks' route_primary is a no-op, so the core owns this). Runs at
    # the refresh_routes cadence, acting services with ha-routes only, and only re-points when
    # the mode host's service actually answers — a promote that ended rc=2 leaves the routes
    # alone until the standby's service comes up (see execute_transition!).
    def reassert_routes(views, modes)
      acting_services.each do |name|
        service = @services[name]
        next unless service.routes.ha_routes?

        desired = modes[name]
        actual = @route_primary[name]
        next if desired == actual || !@cluster.hosts.key?(desired)
        next unless actual.is_a?(String) && @cluster.hosts.key?(actual) # unknown/failed/n/a: nothing trustworthy to correct
        next unless views[desired]&.service_state(name).to_s.start_with?("up")

        $log.warn "[loop] #{name}: routes point at #{actual}, mode is #{desired} and #{name} answers there — re-asserting"
        switch_routes!(service, desired)
      end
    end

    # After a successful promote/demote: the core moves the service's public hostnames to the
    # host the hook made primary (ha-routes mode only; pihole is the hooks' business, off nothing).
    def switch_routes!(service, target)
      routes = service.routes
      return unless routes.ha_routes? && @cluster.hosts.key?(target)

      result = @routes.set_primary(target, bin: @config[:ha_routes_bin], timeout: @config[:route_timeout_s],
                                   route_mode: @config[:route_mode], group: routes.group)
      @route_primary[service.name] = target if result == "ok"
      @store.event!("route.set", "group #{routes.group} -> #{target}: #{result}",
                    level: result == "failed" ? "warn" : "info", service: service.name)
      result
    end

    # ---------------------------------------------------------------- actions

    def dispatch(service, action)
      case action
      when :promote
        execute_transition!(service.name, "promote", ["--auto"])
      when :promote_fast
        execute_transition!(service.name, "promote", ["--auto", "--fast"])
      when :failback
        execute_transition!(service.name, "demote", ["--yes", "--auto"])
      when :fence_and_route
        replicate(service, "fence")
      when :stack_check
        replicate(service, "stack")
      when :watch_maintenance
        replicate(service, "warm")
      end
    end

    def replicate(service, what)
      @hooks.run(service.name, "replicate", what) if @hooks.exists?(service.name, "replicate")
    end

    public

    TRANSITION_PLAYS = {
      "promote" => { marker: "promote-failed", success: :standby },
      "demote" => { marker: "failback-failed", success: :primary }
    }.freeze

    # Runs a promote/demote hook under a majority lease (acquire -> renew in the background ->
    # release), then publishes the resulting mode. Used by the loop's own decisions and by the
    # API/MCP actions. Returns the Hooks::Result, or nil when the lease was denied / hook missing.
    def execute_transition!(service_name, hook, args = [])
      service = @services.fetch(service_name)
      play = TRANSITION_PLAYS.fetch(hook) { raise ArgumentError, "unknown transition #{hook}" }
      unless @hooks.exists?(service.name, hook)
        $log.warn "[loop] hook #{service.name}/#{hook} missing, cannot act"
        return nil
      end

      grant = @lease.acquire!(service: service.name, action: hook)
      renewal = renew_in_background(grant)
      begin
        result = @hooks.run(service.name, hook, *args)
      ensure
        renewal[:queue] << :stop
        renewal[:thread].join(1)
        @lease.release!(renewal[:grant] || grant)
      end

      state = @state.for(service.name)
      mode_after = state.mode(default: service.primary)
      @store.set("primary.#{service.name}", mode_after)
      @store.set("primary_at.#{service.name}", iso(@now.call))

      success_mode = play[:success] == :standby ? service.standby : service.primary
      if result.exit_code.zero?
        state.remove!(play[:marker])
        switch_routes!(service, mode_after)
      else
        # rc=2 "transitioned but degraded" no longer routes: a promote whose health wait failed
        # (standby service never up) must not point the public hostnames at a dead stack
        # (a UI container up while its backend never started is not a takeover). The marker stays so
        # the gates keep throttling; reassert_routes moves the routes once the mode host's
        # service actually answers.
        state.touch!(play[:marker])
        if mode_after == success_mode
          notify("#{service.name}-#{service.standby}: #{hook} DEGRADED",
                 "mode=#{mode_after} but #{hook} rc=#{result.exit_code}; public routes NOT moved — " \
                 "they follow as soon as #{service.name} answers on #{mode_after}", "failure")
        end
      end
      @store.event!("transition.end", "#{hook} rc=#{result.exit_code}, mode=#{mode_after}",
                    level: result.exit_code.zero? ? "info" : "warn",
                    service: service.name, exit_code: result.exit_code)
      result
    rescue Lease::Denied => e
      @store.event!("lease.deny", "#{hook} blocked: #{e.message}", level: "warn", service: service.name)
      notify("#{service.name}-#{service.standby}: #{hook} blocked",
             "no majority lease: #{e.reasons.join('; ')}", "warning")
      nil
    end

    private

    def renew_in_background(grant)
      ctl = { grant: grant, queue: Queue.new }
      ctl[:thread] = Workers.safe_thread("lease-renew") do
        loop do
          break if ctl[:queue].pop(timeout: @config[:lease_renew_s]) == :stop

          begin
            ctl[:grant] = @lease.renew!(ctl[:grant])
          rescue Lease::Expired => e
            $log.error "[loop] #{e.message} (the running hook is not interrupted)"
            break
          end
        end
      end
      ctl
    end

    # ---------------------------------------------------------------- publishing / events

    def entry(service, mode:, agreed:, busy:, now:)
      acting = acting?(service.name)
      state = @state.for(service.name)
      {
        primary: service.primary, standby: service.standby, mode: mode, agreed_class: agreed,
        acting: acting, busy: busy, decider: @deciders[service.name].snapshot(now: now),
        standby_stack: acting && mode == service.standby ? state.stack : nil,
        hold: state.hold?, transition: state.transition
      }
    end

    # hold/transition at the top level are node-wide: the global hold, and the transition of
    # whichever service is in one (nil when none).
    def publish(now, views:, classes:, entries:, quorum:)
      primary = entries.transform_values { |e| e[:mode] }
      primary_at = @services.to_h do |name, _|
        since = @state.for(name).mode_since
        [name, @store.get("primary_at.#{name}") || (since && iso(since))]
      end
      transition = entries.values.filter_map { |e| e[:transition] }.first
      view_doc = @gossip.local_view(hosts: views, classes: classes, primary: primary,
                                    primary_at: primary_at, hold: @state.hold?,
                                    transition: transition, quorum: quorum,
                                    transitions: entries.transform_values { |e| e[:transition] })
      doc = {
        at: now, node: @cluster.node_name, quorum: quorum, reachable_peers: @gossip.reachable_peers,
        views: views, classes: classes, services: entries,
        route_primary: @route_primary, ha_connectors: @ha_connectors,
        hold: @state.hold?, transition: transition
      }
      @mutex.synchronize do
        @last = doc
        @peer_view = view_doc
      end
    end

    def live_view(doc)
      primary = (doc["primary"] || {}).dup
      primary_at = (doc["primary_at"] || {}).dup
      transitions = (doc["transitions"] || {}).dup
      acting_services.each do |name|
        state = @state.for(name)
        transitions[name] = state.transition
        since = state.mode_since
        next unless since

        begin
          primary[name] = state.mode(default: @services[name].primary)
        rescue State::Corrupt => e
          $log.warn "[loop] #{name}: #{e.message}; peer view keeps the cycle primary"
          next
        end
        stored = @store.get("primary_at.#{name}")
        stored_t = stored && Time.iso8601(stored)
        primary_at[name] = iso(stored_t && stored_t > since ? stored_t : since)
      end
      doc.merge("primary" => primary, "primary_at" => primary_at, "transitions" => transitions,
                "transition" => transitions.values.compact.first, "hold" => @state.hold?)
    end

    def record_class_change(service, agreed, mode)
      prev = @svc[service.name][:prev_agreed]
      return if agreed == prev

      @store.event!("class.change", "#{service.primary}: #{prev || 'none'} -> #{agreed} (mode #{mode})",
                    host: service.primary, service: service.name)
      @svc[service.name][:prev_agreed] = agreed
    end

    def heartbeat(now, entries, quorum)
      return if @last_heartbeat && (now - @last_heartbeat) < @config[:heartbeat_s]

      @last_heartbeat = now
      peers = @gossip.reachable_peers.join(",")
      entries.each do |name, e|
        @store.event!("heartbeat", "mode=#{e[:mode]} agreed=#{e[:agreed_class]} quorum=#{quorum} " \
                                   "peers=#{peers}", service: name)
      end
    end

    def prune_if_due(now)
      return unless @config[:events_keep_days]
      return if @last_prune && (now - @last_prune) < PRUNE_INTERVAL_S

      @last_prune = now
      counts = @store.prune!(keep_days: @config[:events_keep_days])
      @store.event!("prune", "older than #{@config[:events_keep_days]}d: " \
                             "#{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}")
    end

    def notify(title, body, type)
      @store.event!("notify", "#{title}: #{body}", level: type == "success" ? "info" : "warn")
      @notifier&.call(title, body, type)
    rescue StandardError => e
      $log.warn "[loop] notifier failed: #{e.class}: #{e.message}"
    end

    def probes_str(view)
      return nil unless view

      "ssh=#{view.ssh || '-'} icmp=#{view.icmp || '-'} https=#{view.https || '-'}"
    end

    def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
