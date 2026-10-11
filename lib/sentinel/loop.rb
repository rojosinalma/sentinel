# frozen_string_literal: true

require "time"

module Sentinel
  # The cycle: probe -> classify -> gossip -> agree -> decide -> act. One instance per process;
  # start! runs it in a bounded background thread at POLL_INTERVAL_S. Only the acting node
  # (the service's standby) ever dispatches an action, and only under a majority lease.
  #
  # config keys (symbols): poll_interval_s, tcp_timeout_s, http_timeout_s, host_health_interval_s,
  # heartbeat_s, lease_renew_s, auto_promote, auto_failback, basic ([user, pass] | nil),
  # plus everything the Decider takes.
  class Loop
    def initialize(config:, cluster:, store:, state:, probes:, gossip:, lease:, hooks:, decider:,
                   notifier:, now: -> { Time.now })
      @config = config
      @cluster = cluster
      @store = store
      @state = state
      @probes = probes
      @gossip = gossip
      @lease = lease
      @hooks = hooks
      @decider = decider
      @notifier = notifier
      @now = now
      @service = cluster.services.values.first or raise ArgumentError, "no service configured"
      @acting = cluster.node_name == @service.standby
      @mutex = Mutex.new
      @last = nil
      @peer_view = nil
      @stop = false
      @host_health = nil
      @last_health_probe = nil
      @last_heartbeat = nil
      @prev_agreed = nil
    end

    attr_reader :service

    def acting? = @acting

    def last = @mutex.synchronize { @last }
    def peer_view = @mutex.synchronize { @peer_view }

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

      # 1+2: probe every host in parallel, classify locally
      views = probe_all(now)
      tcp_quorum = @probes.quorum(@cluster.quorum_tcp, timeout: @config[:tcp_timeout_s])
      classes = views.to_h { |name, view| [name, classify_host(name, view, tcp_quorum)] }

      # 3+4: gossip, agreement
      @gossip.poll!
      primary_host = @service.primary
      agreed = @gossip.agreed_class(primary_host, classes[primary_host])
      quorum = @gossip.quorum? && tcp_quorum != "down" ? "up" : "down"

      # 5: who is primary
      mode = current_mode

      # 6: a hook holds promote.lock -> observe only
      if @state.busy?
        publish(now, mode: mode, views: views, classes: classes, agreed: agreed, quorum: quorum, busy: true)
        return last
      end

      # 7: decide and act (acting node only)
      if @acting
        refresh_host_health(now, mode, views)
        result = @decider.step(
          now: now, mode: mode, agreed_class: agreed, quorum: quorum,
          host_health: @host_health, auto_promote: @config[:auto_promote],
          auto_failback: @config[:auto_failback], probes_str: probes_str(views[primary_host]),
          version: views[primary_host]&.version
        )
        result.log.each { |line| $log.info "[loop] #{line}" }
        result.notify.each { |(title, body, type)| notify(title, body, type) }
        record_class_change(agreed, mode)
        publish(now, mode: mode, views: views, classes: classes, agreed: agreed, quorum: quorum)
        dispatch(result.action, mode, now)
        mode = current_mode # 8: a hook may have moved it
      else
        record_class_change(agreed, mode)
      end

      # 9: publish for /status, /peer/view and the dashboard
      publish(now, mode: mode, views: views, classes: classes, agreed: agreed, quorum: quorum)

      # 10: heartbeat
      heartbeat(now, mode, agreed, quorum)
      last
    end

    private

    # ---------------------------------------------------------------- probing

    def probe_all(now)
      timeout = @config[:tcp_timeout_s]
      jobs = @cluster.hosts.values.to_h do |host|
        url = @service.health[host.name]
        [host.name, lambda do
          @probes.host(host, service_url: url, basic: @config[:basic],
                       timeout: timeout, now: now)
        end]
      end
      Workers.parallel(jobs, timeout: @config[:http_timeout_s] + 1.0).to_h do |name, view|
        view = HostView.new(name: name, probed_at: now).freeze unless view.is_a?(HostView)
        [name, view]
      end
    end

    # The bash classifier is service-centric and applies to hosts that carry the service; a
    # host without one (witness) is judged on reachability alone.
    def classify_host(name, view, quorum)
      return Classifier.classify(view, quorum: quorum) if @service.health.key?(name)

      return :ok if view.any_host_probe_up?

      quorum == "up" ? :dead : :isolated
    end

    # ---------------------------------------------------------------- mode / health

    def current_mode
      if @acting
        @state.mode(default: @service.primary)
      else
        @gossip.primary(@service.name) || @store.get("primary.#{@service.name}") || @service.primary
      end
    end

    # While promoted, the primary host's deeper health (ssh + systemd + docker in phase 2's
    # health hook) is probed at its own cadence; between probes the last answer stands.
    def refresh_host_health(now, mode, views)
      if mode == @service.primary
        @host_health = nil
        @last_health_probe = nil
        return
      end

      ssh = views[@service.primary]&.ssh
      if ssh != "up"
        @host_health = "down ssh-port"
        @last_health_probe = nil
        return
      end

      due = @last_health_probe.nil? || (now - @last_health_probe) >= @config[:host_health_interval_s] ||
            @host_health.nil? || @host_health == "down ssh-port"
      return unless due

      @last_health_probe = now
      @host_health =
        if @hooks.exists?(@service.name, "health")
          @hooks.health(@service.name).exit_code.zero? ? "up" : "down health-hook"
        else
          "up"
        end
    end

    # ---------------------------------------------------------------- actions

    def dispatch(action, mode, now)
      case action
      when :promote, :promote_fast
        args = ["--auto"]
        args << "--fast" if action == :promote_fast
        transition("promote", args, failure_marker: "promote-failed", success_mode: @service.standby)
      when :failback
        transition("demote", ["--yes", "--auto"], failure_marker: "failback-failed", success_mode: @service.primary)
      when :fence_and_route
        @hooks.replicate(@service.name) if @hooks.exists?(@service.name, "replicate")
      when :stack_check
        @hooks.health(@service.name) if @hooks.exists?(@service.name, "health")
      end
    end

    def transition(hook, args, failure_marker:, success_mode:)
      unless @hooks.exists?(@service.name, hook)
        $log.warn "[loop] hook #{@service.name}/#{hook} missing, cannot act"
        return
      end

      grant = @lease.acquire!(service: @service.name, action: hook)
      renewal = renew_in_background(grant)
      begin
        result = @hooks.run(@service.name, hook, *args)
      ensure
        renewal[:queue] << :stop
        renewal[:thread].join(1)
        @lease.release!(renewal[:grant] || grant)
      end

      mode_after = @state.mode(default: @service.primary)
      @store.set("primary.#{@service.name}", mode_after)
      @store.set("primary_at.#{@service.name}", iso(@now.call))

      if result.exit_code.zero? || mode_after == success_mode
        @state.remove!(failure_marker)
      else
        @state.touch!(failure_marker)
      end
      @store.event!("transition.end", "#{hook} rc=#{result.exit_code}, mode=#{mode_after}",
                    level: result.exit_code.zero? ? "info" : "warn",
                    service: @service.name, exit_code: result.exit_code)
    rescue Lease::Denied => e
      @store.event!("lease.deny", "#{hook} blocked: #{e.message}", level: "warn", service: @service.name)
      notify("#{@config[:label]}: #{hook} blocked", "no majority lease: #{e.reasons.join('; ')}", "warning")
    end

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

    def publish(now, mode:, views:, classes:, agreed:, quorum:, busy: false)
      snapshot = @decider.snapshot(now: now)
      primary = { @service.name => mode }
      primary_at = { @service.name => @store.get("primary_at.#{@service.name}") ||
                                      (@state.mode_since && iso(@state.mode_since)) }
      view_doc = @gossip.local_view(hosts: views, classes: classes, primary: primary,
                                    primary_at: primary_at, hold: @state.hold?,
                                    transition: @state.transition, quorum: quorum)
      doc = {
        at: now, node: @cluster.node_name, mode: mode, service: @service.name,
        acting: @acting, busy: busy, views: views, classes: classes, agreed_class: agreed,
        quorum: quorum, reachable_peers: @gossip.reachable_peers, decider: snapshot,
        hold: @state.hold?, transition: @state.transition
      }
      @mutex.synchronize do
        @last = doc
        @peer_view = view_doc
      end
    end

    def record_class_change(agreed, mode)
      return if agreed == @prev_agreed

      @store.event!("class.change", "#{@service.primary}: #{@prev_agreed || 'none'} -> #{agreed} (mode #{mode})",
                    host: @service.primary, service: @service.name)
      @prev_agreed = agreed
    end

    def heartbeat(now, mode, agreed, quorum)
      return if @last_heartbeat && (now - @last_heartbeat) < @config[:heartbeat_s]

      @last_heartbeat = now
      @store.event!("heartbeat", "mode=#{mode} agreed=#{agreed} quorum=#{quorum} " \
                                 "peers=#{@gossip.reachable_peers.join(',')}", service: @service.name)
    end

    def notify(title, body, type)
      @store.event!("notify", "#{title}: #{body}", level: type == "success" ? "info" : "warn")
      @notifier&.call(title, body, type)
    rescue StandardError => e
      $log.warn "[loop] notifier failed: #{e.class}: #{e.message}"
    end

    def probes_str(view)
      return nil unless view

      "ssh=#{view.ssh || '-'} icmp=#{view.icmp || '-'} traefik=#{view.traefik || '-'}"
    end

    def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
