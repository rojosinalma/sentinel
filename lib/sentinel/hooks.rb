# frozen_string_literal: true

require "fileutils"

module Sentinel
  # Runs the per-service bash hooks (hooks/<service>/{health,replicate,promote,demote}) with a
  # bounded lifetime and a log file per run. Exit codes pass through untouched: 0 done, 1 nothing
  # changed, 2 done but degraded — the bash promote/demote contract. services_meta
  # ({service => {primary:, standby:}}) supplies PRIMARY/STANDBY per run; env holds the
  # node-wide variables (ACTING_NODE, STATE_DIR, SN_ENV).
  class Hooks
    Result = Struct.new(:exit_code, :log_file, :duration_s, :output_tail, keyword_init: true)

    TAIL_LINES = 20
    TERM_GRACE_S = 10
    TRANSITION_HOOKS = %w[promote demote].freeze
    ROTATE_BYTES = 5 * 1024 * 1024

    def initialize(dir:, log_dir:, env: {}, services_meta: {}, timeout_s: 900, store: nil)
      @dir = dir
      @log_dir = log_dir
      @env = env
      @services_meta = services_meta
      @timeout_s = timeout_s
      @store = store
      FileUtils.mkdir_p(log_dir)
    end

    def exists?(service, hook) = File.executable?(hook_path(service, hook))

    def health(service) = run(service, "health")
    def replicate(service) = run(service, "replicate")

    def run(service, hook, *args, dry_run: false)
      path = hook_path(service, hook)
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      log_file = log_file_for(hook, ts)
      env = @env.merge(service_env(service), "SERVICE" => service, "DRY_RUN" => dry_run ? "true" : "false")
      transition_id = record_start(service, hook, log_file)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit_code = execute(path, args, env, log_file)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)

      result = Result.new(exit_code: exit_code, log_file: log_file,
                          duration_s: duration, output_tail: tail(log_file)).freeze
      record_end(transition_id, result)
      $log.info "[hooks] #{service}/#{hook} #{args.join(' ')} -> rc=#{exit_code} in #{duration}s (#{log_file})"
      result
    end

    private

    def hook_path(service, hook) = File.join(@dir, service, hook)

    def service_env(service)
      meta = @services_meta[service] or return {}

      { "PRIMARY" => meta[:primary], "STANDBY" => meta[:standby] }
    end

    # promote/demote get one file per run (bash parity: logs/promote-<ts>.log); the frequent
    # hooks (health, replicate) share one appended file, rotated once past ROTATE_BYTES.
    def log_file_for(hook, ts)
      return File.join(@log_dir, "#{hook}-#{ts}.log") if TRANSITION_HOOKS.include?(hook)

      file = File.join(@log_dir, "#{hook}.log")
      File.rename(file, "#{file}.1") if File.exist?(file) && File.size(file) > ROTATE_BYTES
      file
    end

    def execute(path, args, env, log_file)
      File.open(log_file, "a") do |out|
        pid = Process.spawn(env, path, *args.map(&:to_s), out: out, err: out, pgroup: true)
        waiter = Process.detach(pid)
        unless waiter.join(@timeout_s)
          $log.warn "[hooks] #{path} exceeded #{@timeout_s}s, SIGTERM"
          kill_group(pid, "TERM")
          unless waiter.join(TERM_GRACE_S)
            $log.warn "[hooks] #{path} ignored SIGTERM, SIGKILL"
            kill_group(pid, "KILL")
            waiter.join(5)
          end
          out.puts "[hooks] killed after #{@timeout_s}s timeout"
        end
        status = waiter.value
        status.exitstatus || (128 + (status.termsig || 9))
      end
    rescue SystemCallError => e
      $log.error "[hooks] #{path}: #{e.class}: #{e.message}"
      File.write(log_file, "[hooks] spawn failed: #{e.message}\n", mode: "a")
      127
    end

    def kill_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def record_start(service, hook, log_file)
      return nil unless @store && %w[promote demote].include?(hook)

      @store.transition_start!(service: service, action: hook, log_file: log_file)
    end

    def record_end(id, result)
      return unless id

      @store.transition_end!(id, result: result.exit_code.zero? ? "ok" : "failed (rc=#{result.exit_code})",
                                 exit_code: result.exit_code, duration_s: result.duration_s)
    end

    def tail(log_file)
      File.readlines(log_file, chomp: true).last(TAIL_LINES)
    rescue Errno::ENOENT
      []
    end
  end
end
