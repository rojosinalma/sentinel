# frozen_string_literal: true

module Probes
  # Local reads of $NODE_B_ROOT (node-b instance only): state/mode, replica freshness (newest file
  # mtime under replica/opencode and replica/memory) and the latest promote/demote log tail.
  module StandbyRoot
    module_function

    def call(root)
      return { state: "n/a", note: "n/a on #{::Config.fetch('HOST_NAME')}" } if root.to_s.empty?
      return { state: "missing", error: "#{root} is not a directory" } unless File.directory?(root)

      {
        state: "ok",
        root: root,
        mode: read_mode(root),
        replica: { "opencode" => replica(root, "opencode"), "memory" => replica(root, "memory") },
        last_event: last_event(root)
      }
    end

    def read_mode(root)
      path = File.join(root, "state", "mode")
      return { value: "node-a", source: "absent" } unless File.exist?(path)

      word = File.read(path).strip
      word = word[/primary=(\w+)/, 1] if word.start_with?("primary=")
      { value: word, since: File.mtime(path).utc.iso8601, source: path }
    end

    def replica(root, name)
      dir = File.join(root, "replica", name)
      return { state: "missing", dir: dir } unless File.directory?(dir)

      newest = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.map { |f| File.mtime(f) }.max
      return { state: "empty", dir: dir } unless newest

      { state: "ok", dir: dir, newest_at: newest.utc.iso8601, lag_s: (Time.now - newest).round }
    end

    def last_event(root)
      logs = Dir.glob(File.join(root, "logs", "{promote,demote}-*.log")).max_by { |f| File.mtime(f) }
      return nil unless logs

      kind = File.basename(logs)[/\A(promote|demote)/, 1]
      {
        kind: kind,
        file: File.basename(logs),
        at: File.mtime(logs).utc.iso8601,
        tail: tail(logs, ::Config.fetch("LOG_TAIL_LINES"))
      }
    end

    # Reads only the last `lines` lines; the file is never loaded whole.
    def tail(path, lines)
      File.open(path, "rb") do |f|
        chunk = 4096
        buf = +""
        pos = f.size
        while pos > 0 && buf.count("\n") <= lines
          step = [chunk, pos].min
          pos -= step
          f.seek(pos)
          buf = f.read(step) + buf
        end
        buf.split("\n").last(lines).map { |l| l.scrub }
      end
    end
  end
end
