# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class RoutesTest < Minitest::Test
  def stub_bin(script)
    dir = tmp_state_dir
    bin = File.join(dir, "bin", "ha-routes")
    FileUtils.mkdir_p(File.dirname(bin))
    File.write(bin, "#!/usr/bin/env bash\n#{script}\n")
    FileUtils.chmod(0o755, bin)
    bin
  end

  def test_primary_current
    bin = stub_bin('[[ "$1" == get ]] && echo tiny')
    assert_equal "tiny", Sentinel::Routes.primary_current(bin: bin, timeout: 5)
  end

  def test_primary_current_mixed_truncated
    bin = stub_bin("echo mixed")
    assert_equal "mixed", Sentinel::Routes.primary_current(bin: bin, timeout: 5)
  end

  def test_primary_current_failure_unknown
    bin = stub_bin("exit 2")
    assert_equal "unknown", Sentinel::Routes.primary_current(bin: bin, timeout: 5)
  end

  def test_primary_current_timeout_unknown
    bin = stub_bin("sleep 30")
    started = Time.now
    assert_equal "unknown", Sentinel::Routes.primary_current(bin: bin, timeout: 1)
    assert_operator Time.now - started, :<, 10
  end

  def test_primary_current_off_and_missing
    assert_equal "n/a", Sentinel::Routes.primary_current(bin: "/nope", timeout: 1, route_mode: "off")
    assert_equal "unknown", Sentinel::Routes.primary_current(bin: "/nope", timeout: 1)
    assert_equal "unknown", Sentinel::Routes.primary_current(bin: "", timeout: 1)
  end

  def test_set_primary
    bin = stub_bin('[[ "$1 $2" == "set tiny" ]] || exit 1')
    assert_equal "ok", Sentinel::Routes.set_primary("tiny", bin: bin, timeout: 5)
    assert_equal "failed", Sentinel::Routes.set_primary("silver", bin: bin, timeout: 5)
    assert_equal "skipped", Sentinel::Routes.set_primary("tiny", bin: bin, timeout: 5, route_mode: "off")
  end

  def test_routes_env_tunnel_id
    bin = stub_bin("true")
    File.write(File.expand_path("../../routes.env", bin), "FOO=1\nHA_TUNNEL_ID=abc-123\n")
    assert_equal "abc-123", Sentinel::Routes.routes_env_tunnel_id(bin)
    assert_nil Sentinel::Routes.routes_env_tunnel_id("/nonexistent/bin/x")
  end

  def test_connectors_without_creds_is_nil
    assert_nil Sentinel::Routes.connectors_current(bin: "", timeout: 1, tunnel_id: "", token: "", account_id: "")
    assert_nil Sentinel::Routes.connectors_current(bin: nil, timeout: 1, tunnel_id: "t", token: nil, account_id: "a")
  end
end
