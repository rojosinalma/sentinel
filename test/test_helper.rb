# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["LOG_LEVEL"] ||= "warn"

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "time"

require_relative "../lib/log"
require_relative "../lib/sentinel"

# Deterministic time source for the pure state machines (Decider, Gossip, Lease).
class FakeClock
  attr_reader :now

  def initialize(start = Time.utc(2026, 1, 1, 12, 0, 0))
    @now = start
  end

  def advance(seconds)
    @now += seconds
  end

  def to_proc = -> { @now }
end

module SentinelTestHelpers
  TMP_DIRS = []

  # A fresh bash-compatible state directory, removed after the run.
  def tmp_state_dir
    dir = Dir.mktmpdir("sentinel-test-")
    TMP_DIRS << dir
    dir
  end

  def memory_store = Sentinel::Store.memory
end

Minitest::Test.include(SentinelTestHelpers)
Minitest.after_run { SentinelTestHelpers::TMP_DIRS.each { |d| FileUtils.remove_entry(d, true) } }
