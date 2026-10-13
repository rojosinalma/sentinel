# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class HooksTest < Minitest::Test
  def setup
    @state_dir = tmp_state_dir
    @log_dir = File.join(tmp_state_dir, "logs")
    @store = memory_store
    @hooks = Sentinel::Hooks.new(
      dir: File.expand_path("../hooks", __dir__), log_dir: @log_dir,
      env: { "ACTING_NODE" => "node-b", "PRIMARY" => "node-a", "STANDBY" => "node-b",
             "STATE_DIR" => @state_dir },
      timeout_s: 5, store: @store
    )
  end

  def test_exists
    assert @hooks.exists?("_example", "promote")
    refute @hooks.exists?("_example", "nope")
    refute @hooks.exists?("ghost-service", "promote")
  end

  def test_promote_runs_and_writes_mode
    result = @hooks.run("_example", "promote", "--auto")
    assert_equal 0, result.exit_code
    assert File.file?(result.log_file)
    assert(result.output_tail.any? { |l| l.include?("args=--auto") })
    assert(result.output_tail.any? { |l| l.include?("SERVICE=_example") })
    assert_equal "node-b\n", File.read(File.join(@state_dir, "_example", "mode"))

    row = @store.transitions(service: "_example").first
    assert_equal "promote", row[:action]
    assert_equal "ok", row[:result]
    assert_equal 0, row[:exit_code]
    refute_nil row[:finished_at]
  end

  def test_services_meta_supplies_primary_standby_per_service
    hooks = Sentinel::Hooks.new(
      dir: File.expand_path("../hooks", __dir__), log_dir: @log_dir,
      env: { "ACTING_NODE" => "node-b", "STATE_DIR" => @state_dir },
      services_meta: { "_example" => { primary: "alpha", standby: "beta" } },
      timeout_s: 5, store: @store
    )
    result = hooks.run("_example", "promote")
    assert(result.output_tail.any? { |l| l.include?("PRIMARY=alpha STANDBY=beta") })
    assert_equal "beta\n", File.read(File.join(@state_dir, "_example", "mode"))
  end

  def test_demote_writes_primary_back
    @hooks.run("_example", "promote")
    @hooks.run("_example", "demote", "--yes")
    assert_equal "node-a\n", File.read(File.join(@state_dir, "_example", "mode"))
  end

  def test_dry_run_touches_nothing
    result = @hooks.run("_example", "promote", dry_run: true)
    assert_equal 0, result.exit_code
    refute File.exist?(File.join(@state_dir, "_example", "mode"))
    assert(result.output_tail.any? { |l| l.include?("DRY_RUN=true") })
  end

  def test_state_dir_is_per_service_and_logs_carry_the_service_name
    dir = tmp_state_dir
    FileUtils.mkdir_p(File.join(dir, "svc"))
    File.write(File.join(dir, "svc", "promote"), "#!/usr/bin/env bash\necho \"STATE_DIR=$STATE_DIR NODE_STATE_DIR=$NODE_STATE_DIR\"\n")
    FileUtils.chmod(0o755, File.join(dir, "svc", "promote"))
    hooks = Sentinel::Hooks.new(dir: dir, log_dir: @log_dir, env: { "STATE_DIR" => @state_dir }, timeout_s: 5)

    result = hooks.run("svc", "promote")
    assert_includes result.output_tail, "STATE_DIR=#{File.join(@state_dir, 'svc')} NODE_STATE_DIR=#{@state_dir}"
    assert File.directory?(File.join(@state_dir, "svc"))
    assert_match(%r{/svc-promote-\d{8}T\d{6}Z\.log\z}, result.log_file)
    assert_equal File.join(@log_dir, "svc-health.log"), hooks.run("svc", "health").log_file
  end

  def test_hooks_dir_from_services_meta_wins_over_dir
    custom = File.join(tmp_state_dir, "elsewhere")
    FileUtils.mkdir_p(custom)
    File.write(File.join(custom, "promote"), "#!/usr/bin/env bash\necho custom\n")
    FileUtils.chmod(0o755, File.join(custom, "promote"))
    hooks = Sentinel::Hooks.new(dir: File.expand_path("../hooks", __dir__), log_dir: @log_dir, env: {},
                                services_meta: { "_example" => { primary: "a", standby: "b", hooks_dir: custom } },
                                timeout_s: 5)
    assert_equal custom, hooks.hooks_dir("_example")
    assert hooks.exists?("_example", "promote")
    refute hooks.exists?("_example", "demote")
    assert_includes hooks.run("_example", "promote").output_tail, "custom"
  end

  def test_health_is_not_a_transition
    result = @hooks.health("_example")
    assert_equal 0, result.exit_code
    assert_empty @store.transitions
  end

  def test_missing_hook_is_127
    result = @hooks.run("ghost-service", "promote")
    assert_equal 127, result.exit_code
  end

  def test_timeout_kills
    dir = tmp_state_dir
    FileUtils.mkdir_p(File.join(dir, "svc"))
    hook = File.join(dir, "svc", "promote")
    File.write(hook, "#!/usr/bin/env bash\ntrap '' TERM\necho started\nsleep 60\n")
    FileUtils.chmod(0o755, hook)

    hooks = Sentinel::Hooks.new(dir: dir, log_dir: @log_dir, env: {}, timeout_s: 1, store: @store)
    started = Time.now
    result = hooks.run("svc", "promote")
    assert_operator Time.now - started, :<, 20
    refute_equal 0, result.exit_code
    row = @store.transitions(service: "svc").first
    assert_match(/failed/, row[:result])
  end
end
