# frozen_string_literal: true

module Sentinel
  # Thread helpers: every Thread.new goes through here so errors are logged with a backtrace.
  # Fan-out is bounded by the number of jobs handed in; long-lived concurrency goes through Pool.
  module Workers
    module_function

    def safe_thread(name, &block)
      Thread.new do
        block.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        log_error(name, e)
        nil
      end.tap { |t| t.name = name }
    end

    # name => lambda in, name => result out; a job that overruns the shared deadline is killed
    # and reported as {state: "timeout"}. A crashed job yields nil (logged by safe_thread).
    def parallel(jobs, timeout:)
      threads = jobs.to_h { |name, job| [name, safe_thread("job-#{name}") { job.call }] }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      threads.to_h do |name, thread|
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if thread.join([left, 0].max)
          [name, thread.value]
        else
          thread.kill
          $log.warn "[workers] job #{name} exceeded #{timeout}s, killed"
          [name, { state: "timeout", error: "job exceeded #{timeout}s" }]
        end
      end
    end

    def log_error(name, error)
      $log.error "[thread] #{name}: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}"
    end

    # Fixed worker count plus a capped queue: work beyond the cap is rejected, never buffered
    # without bound.
    class Pool
      class Full < StandardError; end

      SHUTDOWN = Object.new
      private_constant :SHUTDOWN

      def initialize(size:, queue: size * 8)
        @max_queue = queue
        @queue = Queue.new
        @mutex = Mutex.new
        @threads = size.times.map { |i| Workers.safe_thread("pool-#{i}") { worker_loop } }
      end

      def post(&block)
        @mutex.synchronize do
          raise Full, "queue full (#{@max_queue})" if @queue.size >= @max_queue

          @queue << block
        end
        nil
      end

      def shutdown
        @threads.size.times { @queue << SHUTDOWN }
        @threads.each { |t| t.join(5) }
        nil
      end

      private

      def worker_loop
        loop do
          job = @queue.pop
          break if job.equal?(SHUTDOWN)

          begin
            job.call
          rescue Exception => e # rubocop:disable Lint/RescueException
            Workers.log_error("pool", e)
          end
        end
      end
    end
  end
end
