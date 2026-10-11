# frozen_string_literal: true

# Route-level tests over Rack::MockRequest: the real App with a real (not started) sentinel
# runtime against a 127.0.0.1 cluster. ENV is set at load time, before App/boot! resolve it.
require_relative "test_helper"
require "rack/mock"
require "fileutils"
require "yaml"

APP_TEST_ROOT = Dir.mktmpdir("sentinel-app-test-")
SentinelTestHelpers::TMP_DIRS << APP_TEST_ROOT

APP_CLUSTER = <<~YAML
  hosts:
    silver:   {address: 127.0.0.1, sentinel_url: http://127.0.0.1:1, role: member, probes: {ssh: 1}}
    tiny:     {address: 127.0.0.1, sentinel_url: http://127.0.0.1:2, role: member, probes: {ssh: 1}}
    witness-1: {address: 127.0.0.1, sentinel_url: http://127.0.0.1:3, role: witness, probes: {ssh: 1}}
  quorum_tcp: []
  services:
    opencode:
      primary: silver
      standby: tiny
      health: {silver: "http://127.0.0.1:1/api/info", tiny: "http://127.0.0.1:2/api/info"}
      hooks_dir: hooks/opencode
YAML

File.write(File.join(APP_TEST_ROOT, "cluster.yml"), APP_CLUSTER)
{
  "NODE_NAME" => "tiny",
  "CLUSTER_FILE" => File.join(APP_TEST_ROOT, "cluster.yml"),
  "STATE_DIR" => File.join(APP_TEST_ROOT, "state"),
  "LOG_DIR" => File.join(APP_TEST_ROOT, "logs"),
  "DB_PATH" => File.join(APP_TEST_ROOT, "sentinel.db"),
  "SENTINEL_MCP_TOKEN" => "test-token",
  "TINY_ROOT" => APP_TEST_ROOT,
  "OPENCODE_DATA_DIR" => File.join(APP_TEST_ROOT, "data"),
  "OPENCODE_CONFIG_DIR" => File.join(APP_TEST_ROOT, "config"),
  "SILVER_HOST" => "127.0.0.1",
  "SILVER_OPENCODE_URL" => "http://127.0.0.1:1",
  "TCP_TIMEOUT_S" => "1",
  "HTTP_TIMEOUT_S" => "1",
  "PEER_TIMEOUT_S" => "1",
  "ROUTE_MODE" => "off"
}.each { |k, v| ENV[k] = v }
Sentinel::Config.reset!

require_relative "../app"

class AppTest < Minitest::Test
  def self.runtime
    @runtime ||= Sentinel.boot!
  end

  def setup
    @rt = self.class.runtime
    @mock = Rack::MockRequest.new(App)
  end

  def test_status_route_byte_compatible_fallback
    res = @mock.get("/status")
    assert_equal 200, res.status
    assert_equal "application/json", res.headers["content-type"]
    assert_equal "no-store", res.headers["cache-control"]
    body = JSON.parse(res.body)
    assert_equal "silver", body["mode"]
    assert_includes res.body, '"mode":"silver"', "compact for litestream-guard"
  end

  def test_peer_view_route
    @rt[:loop].cycle!
    res = @mock.get("/peer/view")
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal "tiny", body["node"]
    assert body.key?("hosts")
    assert body.key?("seq")
  end

  def test_peer_lease_grant_and_deny
    res = @mock.post("/peer/lease", input: JSON.generate(
      service: "opencode", holder: "silver", action: "promote", ttl_s: 30, token: "x"
    ), "CONTENT_TYPE" => "application/json")
    assert_equal 409, res.status
    assert_match(/not the standby/, JSON.parse(res.body)["message"])

    res = @mock.post("/peer/lease", input: "not json", "CONTENT_TYPE" => "application/json")
    assert_equal 400, res.status
  end

  def test_api_sentinel
    res = @mock.get("/api/sentinel")
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert body["ok"]
    assert_equal "tiny", body["node"]
    assert body["acting"]
    assert_equal "opencode", body["service"]
    assert_equal "witness", body["roles"]["witness-1"]
  end

  def test_api_hold_roundtrip
    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "true" }).body)
    assert res["ok"]
    assert res["hold"]
    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "false" }).body)
    assert res["ok"]
    refute res["hold"]
  end

  def test_api_promote_requires_confirmation
    res = JSON.parse(@mock.post("/api/promote").body)
    refute res["ok"]
    assert_match(/confirmation failed/, res["message"])
  end

  def test_api_demote_requires_confirmation
    res = JSON.parse(@mock.post("/api/demote").body)
    refute res["ok"]
    assert_match(/confirmation failed/, res["message"])
  end

  def test_api_promote_dry_run_runs_real_hook
    res = JSON.parse(@mock.post("/api/promote", params: { "dry_run" => "true" }).body)
    assert res["ok"], res["message"]
    assert_match(/rc=0/, res["message"])
    assert_match(/dry-run/, res["message"])
  end

  def test_api_events_and_transitions
    @rt[:store].event!("decision", "test event")
    res = JSON.parse(@mock.get("/api/events?limit=5").body)
    assert res["ok"]
    assert(res["events"].any? { |e| e["message"] == "test event" })

    res = JSON.parse(@mock.get("/api/transitions").body)
    assert res["ok"]
    assert res.key?("transitions")
  end

  def test_mcp_requires_bearer
    res = @mock.post("/mcp", input: "{}", "CONTENT_TYPE" => "application/json")
    assert_equal 401, res.status

    res = @mock.post("/mcp", input: "{}", "CONTENT_TYPE" => "application/json",
                             "HTTP_AUTHORIZATION" => "Bearer wrong")
    assert_equal 401, res.status
  end

  def test_mcp_tools_list_and_status_call
    res = mcp_rpc("tools/list", {})
    tools = res.dig("result", "tools").map { |t| t["name"] }
    assert_includes tools, "status"
    assert_includes tools, "events"
    assert_includes tools, "hold"
    assert_includes tools, "promote"
    assert_includes tools, "demote"
    assert_includes tools, "cluster"

    res = mcp_rpc("tools/call", { name: "status", arguments: {} })
    text = res.dig("result", "content", 0, "text")
    assert_includes text, '"mode"'
  end

  def test_mcp_promote_refused_without_confirm
    res = mcp_rpc("tools/call", { name: "promote", arguments: {} })
    text = res.dig("result", "content", 0, "text")
    assert_includes text, "refused"
  end

  def test_legacy_page_still_renders
    res = @mock.get("/")
    assert_equal 200, res.status
    assert_includes res.body, "sentinel"
    res = @mock.get("/health")
    assert JSON.parse(res.body)["ok"]
  end

  private

  def mcp_rpc(method, params)
    res = @mock.post("/mcp",
                     input: JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params),
                     "CONTENT_TYPE" => "application/json",
                     "HTTP_ACCEPT" => "application/json, text/event-stream",
                     "HTTP_AUTHORIZATION" => "Bearer test-token")
    assert_equal 200, res.status, res.body
    JSON.parse(res.body)
  end
end
