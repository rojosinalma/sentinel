# frozen_string_literal: true

# Thread helpers: every Thread.new in the app goes through here so errors are logged with a
# backtrace, and parallel fan-out is bounded by the number of jobs handed in (never a growing pool).
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

  # Runs each job in its own thread, waits at most `timeout` seconds for all of them and returns
  # a hash of name => result. A job that overruns is killed and reported as a timeout, so one hung
  # probe can neither stall the response nor leak a thread.
  def parallel(jobs, timeout:)
    threads = jobs.to_h { |name, job| [name, safe_thread("probe-#{name}") { job.call }] }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    threads.to_h do |name, thread|
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      finished = thread.join([left, 0].max)
      if finished
        [name, thread.value]
      else
        thread.kill
        $log.warn "[workers] probe #{name} exceeded #{timeout}s, killed"
        [name, { state: "timeout", error: "probe exceeded #{timeout}s" }]
      end
    end
  end

  def log_error(name, error)
    $log.error "[thread] #{name}: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}"
  end
end
