# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

class RoutesTest < Minitest::Test
  HOSTS = %w[node-a node-b witness-1].freeze

  def setup = Sentinel::Routes.reset!

  def stub_bin(script)
    dir = tmp_state_dir
    bin = File.join(dir, "bin", "ha-routes")
    FileUtils.mkdir_p(File.dirname(bin))
    File.write(bin, "#!/usr/bin/env bash\n#{script}\n")
    FileUtils.chmod(0o755, bin)
    bin
  end

  # A group-aware fake: --help advertises --group; `get --group g` answers per group from
  # $ROUTES_FAKE (group=host lines); `set` appends its argv to $ROUTES_FAKE_LOG.
  GROUPED = <<~'BASH'
    case "$1" in
      --help) echo "ha-routes set <primary> [--group <name>] [--dry-run] | get [--group <name>] | get --all"; exit 0 ;;
    esac
    cmd="$1"; shift; group=""; all=false; target=""
    while (( $# )); do
      case "$1" in --group) group="$2"; shift ;; --all) all=true ;; *) target="$1" ;; esac; shift
    done
    [[ -n "${ROUTES_FAKE_LOG:-}" ]] && echo "$cmd $target ${group:+--group $group}" >> "$ROUTES_FAKE_LOG"
    case "$cmd" in
      get)
        if $all; then printf '%s\n' $ROUTES_FAKE; exit 0; fi
        g="${group:-opencode}"
        for kv in $ROUTES_FAKE; do [[ "${kv%%=*}" == "$g" ]] && { echo "${kv#*=}"; exit 0; }; done
        exit 1 ;;
      set) [[ "$target" == node-a || "$target" == node-b ]] ;;
    esac
  BASH

  # The pre-group script: no --group in --help, `get` prints one primary, `set <host>` only.
  LEGACY = <<~'BASH'
    case "$1" in
      --help) echo "ha-routes set <primary> [--dry-run] | get | show"; exit 0 ;;
      get) [[ $# -eq 1 ]] || exit 1; echo node-a ;;
      set) [[ $# -eq 2 && "$2" == node-b ]] || exit 1; [[ -n "${ROUTES_FAKE_LOG:-}" ]] && echo "$*" >> "$ROUTES_FAKE_LOG" ;;
    esac
  BASH

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_primary_current
    bin = stub_bin('[[ "$1" == get ]] && echo node-b')
    assert_equal "node-b", Sentinel::Routes.primary_current(bin: bin, timeout: 5)
  end

  def test_primary_current_mixed_truncated
    bin = stub_bin("echo mixed")
    assert_equal "mixed", Sentinel::Routes.primary_current(bin: bin, timeout: 5, hosts: HOSTS)
    bin = stub_bin("printf 'x%.0s' {1..80}")
    assert_equal 40, Sentinel::Routes.primary_current(bin: bin, timeout: 5, hosts: HOSTS).size
  end

  def test_primary_current_accepts_any_cluster_host
    bin = stub_bin("echo witness-1")
    assert_equal "witness-1", Sentinel::Routes.primary_current(bin: bin, timeout: 5, hosts: HOSTS)
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
    bin = stub_bin('[[ "$1 $2" == "set node-b" ]] || exit 1')
    assert_equal "ok", Sentinel::Routes.set_primary("node-b", bin: bin, timeout: 5)
    assert_equal "failed", Sentinel::Routes.set_primary("node-a", bin: bin, timeout: 5)
    assert_equal "skipped", Sentinel::Routes.set_primary("node-b", bin: bin, timeout: 5, route_mode: "off")
  end

  def test_groups_get_and_set
    bin = stub_bin(GROUPED)
    log = File.join(tmp_state_dir, "calls.log")
    with_env("ROUTES_FAKE" => "opencode=node-a hangar=node-b", "ROUTES_FAKE_LOG" => log) do
      assert Sentinel::Routes.supports_groups?(bin, timeout: 5)
      assert_equal "node-a", Sentinel::Routes.primary_current(bin: bin, timeout: 5, group: "opencode", hosts: HOSTS)
      assert_equal "node-b", Sentinel::Routes.primary_current(bin: bin, timeout: 5, group: "hangar", hosts: HOSTS)
      assert_equal "unknown", Sentinel::Routes.primary_current(bin: bin, timeout: 5, group: "ghost", hosts: HOSTS)
      assert_equal "ok", Sentinel::Routes.set_primary("node-b", bin: bin, timeout: 5, group: "hangar")
      assert_equal "failed", Sentinel::Routes.set_primary("mars", bin: bin, timeout: 5, group: "hangar")
    end
    calls = File.readlines(log, chomp: true)
    assert_includes calls, "get  --group opencode"
    assert_includes calls, "get  --group hangar"
    assert_includes calls, "set node-b --group hangar"
  end

  def test_get_all_lists_every_group
    bin = stub_bin(GROUPED)
    with_env("ROUTES_FAKE" => "opencode=node-a hangar=node-b") do
      out = Sentinel::Routes.capture(bin, "get", "--all", timeout: 5)
      assert_equal %w[opencode=node-a hangar=node-b], out.lines(chomp: true)
    end
  end

  def test_legacy_ha_routes_gets_group_less_calls
    bin = stub_bin(LEGACY)
    log = File.join(tmp_state_dir, "calls.log")
    with_env("ROUTES_FAKE_LOG" => log) do
      refute Sentinel::Routes.supports_groups?(bin, timeout: 5)
      assert_equal "node-a", Sentinel::Routes.primary_current(bin: bin, timeout: 5, group: "opencode", hosts: HOSTS)
      assert_equal "ok", Sentinel::Routes.set_primary("node-b", bin: bin, timeout: 5, group: "opencode")
    end
    assert_equal ["set node-b"], File.readlines(log, chomp: true)
  end

  def test_group_support_is_cached_per_binary_mtime
    bin = stub_bin(LEGACY)
    refute Sentinel::Routes.supports_groups?(bin, timeout: 5)
    File.write(bin, "#!/usr/bin/env bash\n#{GROUPED}\n")
    File.utime(Time.now + 5, Time.now + 5, bin)
    assert Sentinel::Routes.supports_groups?(bin, timeout: 5), "a newer synced-in copy is re-probed"
  end

  def test_routes_env_tunnel_id
    bin = stub_bin("true")
    File.write(File.expand_path("../../routes.env", bin), "FOO=1\nHA_TUNNEL_ID=abc-123\n")
    assert_equal "abc-123", Sentinel::Routes.routes_env_tunnel_id(bin)
    assert_nil Sentinel::Routes.routes_env_tunnel_id("/nonexistent/bin/x")
    explicit = File.join(File.dirname(bin), "other.env")
    File.write(explicit, "HA_TUNNEL_ID=from-env-file\n")
    assert_equal "from-env-file", Sentinel::Routes.routes_env_tunnel_id(bin, env_file: explicit), "ROUTES_ENV_FILE wins"
    assert_equal "from-env-file", Sentinel::Routes.routes_env_tunnel_id("", env_file: explicit), "no binary needed"
    assert_equal "abc-123", Sentinel::Routes.routes_env_tunnel_id(bin, env_file: ""), "empty falls back to the legacy path"
  end

  def test_connectors_without_creds_is_nil
    assert_nil Sentinel::Routes.connectors_current(bin: "", timeout: 1, tunnel_id: "", token: "", account_id: "")
    assert_nil Sentinel::Routes.connectors_current(bin: nil, timeout: 1, tunnel_id: "t", token: nil, account_id: "a")
  end
end
