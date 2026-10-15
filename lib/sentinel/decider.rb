# frozen_string_literal: true

require "time"

module Sentinel
  # The decision state machine (primary-down cycle, failback cycle, promote gate). Pure: no I/O beyond the injected State (hold, file ages, flips), no clock of
  # its own. One step per poll; the Result says what the loop should do.
  #
  # config keys (Hash, symbols): primary, standby, service, label, quorum_targets,
  # promote_after_s, failback_after_s, promote_cooldown_s, promote_retry_s, failback_retry_s,
  # flap_flips, flap_window_s, flap_failback_after_s, dead_confirm_polls, notify_down_after_s,
  # fence_interval_s, stack_check_interval_s.
  #
  # Deviation from docs/architecture.md: Result#notify is an Array of [title, body, type]
  # tuples ([] when none) because one bash cycle can send two notifications (e.g. down + isolated).
  class Decider
    Result = Struct.new(:action, :notify, :log, :gates, keyword_init: true)

    attr_reader :classification, :config

    def initialize(config:, state:)
      @c = config
      @config = config
      @state = state
      @log_every_last = {}
      @classification = :ok
      @flips = 0
      @stack = nil
      @last_watch = nil
      reset_primary_watch!
      reset_standby_watch!
    end

    def step(now:, mode:, agreed_class:, quorum:, auto_promote:, auto_failback:,
             host_health: nil, probes_str: nil, version: nil)
      @log = []
      @notify = []
      @now = now
      @flips = @state.flips_in_window(@c[:flap_window_s], now: now)
      @flap_notified = false if @flips < @c[:flap_flips]

      if mode == @c[:primary]
        primary_cycle(now, agreed_class, quorum, auto_promote, probes_str, version)
      else
        standby_cycle(now, host_health, auto_failback)
      end
    end

    # What /status needs from the decider, bash field names on the right.
    def snapshot(now: @now || Time.now)
      {
        classification: @classification.to_s,
        dead_polls: @dead_polls,
        down_since: @down_since && iso(@down_since),
        stable_since: @stable_since && iso(@stable_since),   # silver_stable_since
        host_health: @host_health,                           # silver_host_health
        stack: @stack,                                       # tiny_stack (legacy) / standby_stack
        flips_in_window: @flips,
        promote_cooldown_left_s: cooldown_left(now),
        promote_retry_left_s: promote_retry_left(now),
        failback_retry_left_s: failback_retry_left(now),
        failback_after_s: effective_failback_after
      }
    end

    def reset_for_mode!(_mode)
      reset_primary_watch!
      reset_standby_watch!
      @last_watch = nil
      @classification = :ok
    end

    private

    # ---------------------------------------------------------------- mode == primary

    def primary_cycle(now, cls, quorum, auto_promote, probes_str, version)
      reset_standby_watch!
      # Warm-follower upkeep (hooks/<service>/replicate warm) runs on the primary's own cadence
      # regardless of class; promotions outrank it in the single action slot.
      watch_due = @last_watch.nil? || now - @last_watch >= @c[:stack_check_interval_s]

      if cls == :ok
        if @down_since
          @log << "#{@c[:primary]} #{@c[:service]} back UP#{version ? " (#{version})" : ''} " \
                  "after being down since #{iso(@down_since)} (#{@classification}, dead_polls #{@dead_polls})"
          if @notified_down
            @notify << ["#{@c[:primary]} #{@c[:service]} back",
                        "up again#{version ? " (#{version})" : ''}, no promotion happened", "success"]
          end
        end
        reset_primary_watch!
        @classification = :ok
        return watch_or_none(now, watch_due)
      end

      # Degraded confirmation: the promote clock starts only after N consecutive non-ok polls
      # (tunable degraded_confirm_polls, default 1 = immediately). One slow/killed probe must
      # not open a 60 s promote window — on 2026-10-13 a loaded primary flapped ok<->degraded
      # for half an hour until 62 s of bad luck promoted the standby.
      @nonok_polls += 1
      if @nonok_polls < @c.fetch(:degraded_confirm_polls, 1)
        throttle(:unconfirmed, now) do
          "#{@c[:primary]} #{@c[:service]} #{cls} (#{@nonok_polls}/#{@c[:degraded_confirm_polls]} polls, not yet confirmed)"
        end
        return watch_or_none(now, watch_due)
      end

      unless @down_since
        @down_since = now
        @log << "#{@c[:primary]} #{@c[:service]} DOWN: #{cls}#{probes_str ? " (#{probes_str} quorum=#{quorum})" : ''}"
      end
      @log << "classification #{@classification} -> #{cls} (down since #{iso(@down_since)})" if cls != @classification
      @classification = cls
      down_for = (now - @down_since).to_i

      if !@notified_down && down_for >= @c[:notify_down_after_s]
        @notified_down = true
        @notify << ["#{@c[:primary]} #{@c[:service]} down",
                    "down for #{down_for}s (#{cls}#{probes_str ? ", #{probes_str}" : ''}); " \
                    "auto-promote #{auto_promote} after #{@c[:promote_after_s]}s", "warning"]
      end

      case cls
      when :dead
        @dead_polls += 1
        @isolated_notified = false
        if @dead_polls == @c[:dead_confirm_polls]
          @log << "#{@c[:primary]} DEAD confirmed: #{@dead_polls} consecutive dead polls (quorum up)"
        end
        if @dead_polls >= @c[:dead_confirm_polls] && promote_gate(now, down_for, auto_promote, quorum)
          return result(:promote_fast)
        end
      when :degraded
        @log << "host answers again; dead counter reset from #{@dead_polls}" if @dead_polls.positive?
        @dead_polls = 0
        @isolated_notified = false
      when :isolated
        @log << "quorum lost; dead counter reset from #{@dead_polls}" if @dead_polls.positive?
        @dead_polls = 0
        unless @isolated_notified
          @isolated_notified = true
          @notify << ["#{@c[:label]}: isolated",
                      "#{@c[:primary]} #{@c[:service]} down but no quorum target answers " \
                      "(#{Array(@c[:quorum_targets]).join(' ')}): #{@c[:standby]} may be the cut-off side, not promoting",
                      "warning"]
        end
      end

      if cls != :dead && down_for >= @c[:promote_after_s] && promote_gate(now, down_for, auto_promote, quorum)
        return result(:promote)
      end

      watch_or_none(now, watch_due)
    end

    def watch_or_none(now, watch_due)
      return result(:none) unless watch_due

      @last_watch = now
      result(:watch_maintenance)
    end

    # The bash gate order: AUTO_PROMOTE -> quorum -> cooldown -> retry. Each block logs, throttled.
    def promote_gate(now, down_for, auto_promote, quorum)
      if auto_promote != "on"
        throttle(:no_promote, now) { "would promote (#{@classification}) but AUTO_PROMOTE=#{auto_promote} (down #{down_for}s)" }
      elsif quorum != "up"
        throttle(:no_quorum, now) { "no quorum: #{@c[:standby]} may be the isolated one, not promoting" }
      elsif (left = cooldown_left(now)).positive?
        throttle(:cooldown, now) { "promote cooldown after the last failback: #{left}s left (down #{down_for}s)" }
      elsif (left = promote_retry_left(now)).positive?
        throttle(:promote_retry, now) { "last promote failed; retry in #{left}s (down #{down_for}s)" }
      else
        return true
      end
      false
    end

    # ---------------------------------------------------------------- mode == standby (promoted)

    def standby_cycle(now, host_health, auto_failback)
      reset_primary_watch!
      @last_watch = nil
      @classification = :ok
      @host_health = host_health

      fence_due = @last_fence.nil? || now - @last_fence >= @c[:fence_interval_s]
      stack_due = @last_stack_check.nil? || now - @last_stack_check >= @c[:stack_check_interval_s]

      if host_health == "up"
        unless @stable_since
          @stable_since = now
          @log << "#{@c[:primary]} host healthy; stable since #{iso(now)}"
        end
      else
        if @stable_since
          @log << "#{@c[:primary]} host not healthy (#{host_health}); was stable since #{iso(@stable_since)}, counter reset"
        end
        @stable_since = nil
        throttle(:unhealthy, now) { "#{@c[:primary]} host: #{host_health}" } if host_health
      end

      if @stable_since && (action = failback_decision(now, auto_failback))
        return result(action)
      end

      # One action slot per cycle: failback outranks the cadences; fence and stack check
      # alternate within a couple of polls, which their intervals absorb.
      if fence_due
        @last_fence = now
        return result(:fence_and_route)
      end
      if stack_due
        @last_stack_check = now
        return result(:stack_check)
      end

      result(:none)
    end

    def failback_decision(now, auto_failback)
      stable_for = (now - @stable_since).to_i
      after = effective_failback_after

      if @flips >= @c[:flap_flips] && !@flap_notified
        @flap_notified = true
        @notify << ["#{@c[:label]}: flapping",
                    "#{@flips} mode changes in the last #{@c[:flap_window_s]}s; " \
                    "failback now needs #{@c[:primary]} stable for #{after}s", "warning"]
      end

      unless stable_for >= after
        throttle(:stable_wait, now) { "#{@c[:primary]} stable for #{stable_for}s, failback at #{after}s" }
        return nil
      end

      if auto_failback != "on"
        throttle(:no_auto, now) { "would fail back but AUTO_FAILBACK=#{auto_failback} (#{@c[:primary]} stable #{stable_for}s)" }
      elsif @state.hold?
        throttle(:hold, now) { "state/hold present: failback blocked (#{@c[:primary]} stable #{stable_for}s)" }
        unless @hold_notified
          @hold_notified = true
          @notify << ["#{@c[:label]}: failback on hold",
                      "#{@c[:primary]} has been healthy for #{stable_for}s but state/hold blocks the demote; " \
                      "'sentinel hold off' releases it", "warning"]
        end
      elsif (left = failback_retry_left(now)).positive?
        throttle(:retry_wait, now) { "last failback failed; retry in #{left}s" }
      else
        @stable_since = nil
        @hold_notified = false
        return :failback
      end
      nil
    end

    # ---------------------------------------------------------------- gates / helpers

    def cooldown_left(now)
      [@c[:promote_cooldown_s] - @state.file_age_s("last-demote", now: now), 0].max
    end

    def promote_retry_left(now)
      [@c[:promote_retry_s] - @state.file_age_s("promote-failed", now: now), 0].max
    end

    def failback_retry_left(now)
      [@c[:failback_retry_s] - @state.file_age_s("failback-failed", now: now), 0].max
    end

    def effective_failback_after
      @flips >= @c[:flap_flips] ? @c[:flap_failback_after_s] : @c[:failback_after_s]
    end

    def throttle(key, now)
      last = @log_every_last[key]
      return if last && now - last < @c[:fence_interval_s]

      @log_every_last[key] = now
      @log << yield
    end

    def result(action)
      Result.new(action: action, notify: @notify, log: @log, gates: snapshot(now: @now)).freeze
    end

    def reset_primary_watch!
      @down_since = nil
      @dead_polls = 0
      @nonok_polls = 0
      @notified_down = false
      @isolated_notified = false
    end

    def reset_standby_watch!
      @stable_since = nil
      @host_health = nil
      @stack = nil
      @hold_notified = false
      @last_fence = nil
      @last_stack_check = nil
    end

    def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
