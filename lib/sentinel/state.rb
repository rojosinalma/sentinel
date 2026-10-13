# frozen_string_literal: true

require "fileutils"
require "time"

module Sentinel
  # The bash-compatible state/ directory. The hooks (bash) and opencode-node-b's bin/verify read
  # and write these files exactly as the bash sentinel did; this class is the only Ruby-side
  # accessor. Nothing here caches: every call reads the filesystem, like the bash did.
  #
  # The node root holds the cluster-wide `hold`; every service owns `STATE_DIR/<service>/`
  # (`for(service)` -> ServiceState) with its mode, transition, lock and markers. The legacy
  # single-service layout is moved into `<service>/` once by `migrate_legacy!`, which leaves
  # `mode` as a symlink so external readers (`cat state/mode` over ssh) keep working.
  class State
    class Corrupt < StandardError; end

    ABSENT_AGE = 999_999_999
    MODE_RE = /\A(?:primary=)?([a-z][a-z0-9_-]*)/
    SERVICE_RE = /\A[a-z_][a-z0-9_-]*\z/
    HISTORY_TAIL = 50
    LEGACY_FILES = %w[mode mode.history transition promote.lock promote-failed failback-failed
                      stack warm.json known_hosts].freeze

    attr_reader :dir

    def initialize(dir)
      @dir = dir
      @services = {}
      @services_mutex = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def path(name) = File.join(@dir, name)

    def for(service)
      raise ArgumentError, "invalid service name #{service.inspect}" unless service.is_a?(String) && service.match?(SERVICE_RE)

      @services_mutex.synchronize do
        @services[service] ||= ServiceState.new(path(service), service: service, node: self)
      end
    end

    # One-off: the opencode-era files at the root move into <service>/ and `mode` becomes a
    # relative symlink to <service>/mode. No-op once done (or when there is nothing to move).
    # Returns the moved file names.
    def migrate_legacy!(service)
      legacy = path("mode")
      target = self.for(service)
      return [] if File.symlink?(legacy) || !File.file?(legacy) || File.file?(target.path("mode"))

      names = (LEGACY_FILES + Dir.children(@dir).grep(/\Alast-/)).uniq
      moved = names.select { |n| File.file?(path(n)) && !File.symlink?(path(n)) }
      moved.each { |n| File.rename(path(n), target.path(n)) }
      File.symlink(File.join(service, "mode"), legacy)
      $log.info "[state] migrated legacy #{service} state into #{target.dir} (#{moved.join(', ')}); mode -> #{service}/mode"
      moved
    end

    # "node-a" | "node-b" (any lowercase word); the legacy "primary=<mode>" form is accepted.
    # Absent file -> default. Unparseable -> Corrupt, like the bash `die`.
    def mode(default:)
      f = path("mode")
      return default unless File.file?(f)

      line = File.open(f, &:gets).to_s
      m = line[MODE_RE, 1]
      raise Corrupt, "unparseable #{f}: #{line.strip[0, 100].inspect}" unless m

      m
    end

    def mode_since
      f = path("mode")
      File.file?(f) ? File.mtime(f) : nil
    end

    # Atomic write + history append, the exact bash set_mode. Hooks normally do this themselves;
    # the Ruby side uses it in tests and from the CLI.
    def set_mode!(mode, now: Time.now)
      raise ArgumentError, "invalid mode #{mode.inspect}" unless mode.is_a?(String) && mode.match?(/\A[a-z][a-z0-9_-]*\z/)

      tmp = path("mode.tmp.#{Process.pid}")
      File.write(tmp, "#{mode}\n")
      File.rename(tmp, path("mode"))
      File.open(path("mode.history"), "a") { |f| f.puts "#{iso(now)} #{mode}" }
      mode
    end

    def hold? = File.exist?(path("hold"))

    def hold_on!(who, now: Time.now)
      File.write(path("hold"), "#{iso(now)} #{who}\n") unless hold?
      nil
    end

    def hold_off!
      FileUtils.rm_f(path("hold"))
      nil
    end

    # "promote <ts>" | "demote <ts>" | nil — written by the hooks while they run.
    def transition
      content = File.read(path("transition")).strip
      content.empty? ? nil : content
    rescue Errno::ENOENT
      nil
    end

    def set_transition!(hook, ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
      File.write(path("transition"), "#{hook} #{ts}\n")
      nil
    end

    def clear_transition! = remove!("transition")

    # The standby stack marker the replicate hook writes ("healthy" | "degraded: …"); the
    # opencode hooks call it stack, the generic name is stack.
    def stack = read("stack") || read("stack")

    # A bash hook holds promote.lock via flock for its lifetime. flock locks conflict across
    # file descriptors, so probing with LOCK_NB is exact even from another process.
    def busy?
      File.open(path("promote.lock"), File::RDONLY) do |f|
        if f.flock(File::LOCK_EX | File::LOCK_NB)
          f.flock(File::LOCK_UN)
          false
        else
          true
        end
      end
    rescue Errno::ENOENT
      false
    end

    def file_age_s(name, now: Time.now)
      (now - File.mtime(path(name))).to_i
    rescue Errno::ENOENT
      ABSENT_AGE
    end

    def touch!(name)
      FileUtils.touch(path(name))
      nil
    end

    def remove!(name)
      FileUtils.rm_f(path(name))
      nil
    end

    # Content of a state file, stripped, or nil when absent (e.g. stack from the hooks).
    def read(name)
      content = File.read(path(name)).strip
      content.empty? ? nil : content
    rescue Errno::ENOENT
      nil
    end

    # Mode changes within the window, from the last HISTORY_TAIL lines of mode.history
    # (lines: "<iso> <mode>"), exactly the bash flips_in_window. Deliberate: a failed demote
    # writes two lines (primary at start, standby at rollback) and therefore counts as two
    # flips — conservative on purpose, since a rollback is itself a sign of instability and the
    # only effect is a longer failback_after. A pattern-based dedupe was tried on 2026-10-14 and
    # rejected: it cannot tell a rollback from a quick re-attempt and undercounts a flip storm.
    def flips_in_window(window_s, now: Time.now)
      f = path("mode.history")
      return 0 unless File.file?(f)

      cutoff = now - window_s
      tail_lines(f, HISTORY_TAIL).count do |line|
        ts = line.split(" ", 2).first
        begin
          Time.iso8601(ts) >= cutoff
        rescue ArgumentError, TypeError
          false
        end
      end
    end

    private

    def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    def tail_lines(file, count)
      lines = File.readlines(file, chomp: true)
      lines.last(count)
    end
  end

  # One service's slice of the state dir (STATE_DIR/<service>/): the same files and methods as
  # the node root, plus the node-wide hold folded into hold?. Hooks get this dir as STATE_DIR.
  class ServiceState < State
    attr_reader :service, :node

    def initialize(dir, service:, node:)
      super(dir)
      @service = service
      @node = node
    end

    undef_method :for, :migrate_legacy!

    # A hold set on the node (all services) or on this service alone.
    def hold? = super || @node.hold?
  end
end
