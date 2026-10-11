# frozen_string_literal: true

require_relative "test_helper"

class WorkersTest < Minitest::Test
  def test_safe_thread_logs_and_returns_nil_on_error
    t = Sentinel::Workers.safe_thread("boom") { raise "nope" }
    assert_nil t.value
  end

  def test_parallel_results
    jobs = { a: -> { 1 }, b: -> { "x" } }
    assert_equal({ a: 1, b: "x" }, Sentinel::Workers.parallel(jobs, timeout: 2))
  end

  def test_parallel_timeout
    jobs = { slow: -> { sleep 5; :done }, fast: -> { :ok } }
    out = Sentinel::Workers.parallel(jobs, timeout: 0.2)
    assert_equal :ok, out[:fast]
    assert_equal "timeout", out[:slow][:state]
  end

  def test_parallel_crashed_job_is_nil
    out = Sentinel::Workers.parallel({ bad: -> { raise "x" } }, timeout: 1)
    assert_nil out[:bad]
  end

  def test_pool_runs_jobs
    pool = Sentinel::Workers::Pool.new(size: 2)
    results = Queue.new
    4.times { |i| pool.post { results << i } }
    got = 4.times.map { results.pop }
    assert_equal [0, 1, 2, 3], got.sort
  ensure
    pool&.shutdown
  end

  def test_pool_full_raises
    pool = Sentinel::Workers::Pool.new(size: 1, queue: 1)
    gate = Queue.new
    started = Queue.new
    pool.post { started << :go; gate.pop } # occupies the worker...
    started.pop                            # ...confirmed picked up, queue is empty again
    pool.post { nil }                      # fills the queue
    assert_raises(Sentinel::Workers::Pool::Full) { pool.post { nil } }
  ensure
    gate&.push(nil)
    pool&.shutdown
  end

  def test_pool_survives_job_errors
    pool = Sentinel::Workers::Pool.new(size: 1)
    results = Queue.new
    pool.post { raise "boom" }
    pool.post { results << :alive }
    assert_equal :alive, results.pop
  ensure
    pool&.shutdown
  end
end
