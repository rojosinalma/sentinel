# frozen_string_literal: true

require "fileutils"
require "time"

module Sentinel
  # The bash-compatible state/ directory. The hooks (bash) and opencode-node-b's bin/verify read
  # and write these files exactly as the bash sentinel did; this class is the only Ruby-side
  # accessor. Nothing here caches: every call reads the filesystem, like the bash did.
  class State
    class Corrupt < StandardError; end

    ABSENT_AGE = 999_999_999
    MODE_RE = /\A(?:primary=)?([a-z][a-z0-9_-]*)/
    HISTORY_TAIL = 50

    attr_reader :dir

    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(dir)
    end

    def path(name) = File.join(@dir, name)

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

    # Mode changes within the window, from the last HISTORY_TAIL lines of mode.history
    # (lines: "<iso> <mode>"), exactly the bash flips_in_window.
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
end
