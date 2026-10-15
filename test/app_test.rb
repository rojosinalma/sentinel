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
    node-a:   {address: 127.0.0.1, sentinel_url: http://127.0.0.1:1, role: member, probes: {ssh: 1}}
    node-b:     {address: 127.0.0.1, sentinel_url: http://127.0.0.1:2, role: member, probes: {ssh: 1}}
    witness-1: {address: 127.0.0.1, sentinel_url: http://127.0.0.1:3, role: witness, probes: {ssh: 1}}
  quorum_tcp: []
  services:
    opencode:
      primary: node-a
      standby: node-b
      health: {node-a: "http://127.0.0.1:1/api/info", node-b: "http://127.0.0.1:2/api/info"}
      hooks_dir: hooks/opencode
YAML

File.write(File.join(APP_TEST_ROOT, "cluster.yml"), APP_CLUSTER)
{
  "NODE_NAME" => "node-b",
  "CLUSTER_FILE" => File.join(APP_TEST_ROOT, "cluster.yml"),
  "STATE_DIR" => File.join(APP_TEST_ROOT, "state"),
  "LOG_DIR" => File.join(APP_TEST_ROOT, "logs"),
  "DB_PATH" => File.join(APP_TEST_ROOT, "sentinel.db"),
  "SENTINEL_MCP_TOKEN" => "test-token",
  "NODE_B_ROOT" => APP_TEST_ROOT, # read by hooks/opencode (dry-run test)
  "OPENCODE_DATA_DIR" => File.join(APP_TEST_ROOT, "data"),
  "OPENCODE_CONFIG_DIR" => File.join(APP_TEST_ROOT, "config"),
  "NODE_A_HOST" => "127.0.0.1",
  "NODE_B_HOST" => "127.0.0.1",
  "SN_ENV" => "/nonexistent-env",
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
    assert_equal "node-a", body["mode"]
    assert_includes res.body, '"mode":"node-a"', "compact for replica-guard"
  end

  def test_peer_view_route
    @rt[:loop].cycle!
    res = @mock.get("/peer/view")
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal "node-b", body["node"]
    assert body.key?("hosts")
    assert body.key?("seq")
  end

  def test_peer_lease_grant_and_deny
    res = @mock.post("/peer/lease", input: JSON.generate(
      service: "opencode", holder: "node-a", action: "promote", ttl_s: 30, token: "x"
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
    assert_equal "node-b", body["node"]
    assert body["acting"]
    assert_equal "opencode", body["service"]
    assert_equal "witness", body["roles"]["witness-1"]
    assert body.key?("standby_stack")
    refute body.key?("standby_stack")
  end

  def test_api_sentinel_and_mcp_cluster_hide_the_lease_token
    @rt[:store].lease_grant!(service: "opencode", holder: "node-b", action: "promote", token: "secret-token", ttl_s: 30)
    body = JSON.parse(@mock.get("/api/sentinel").body)
    assert_equal "node-b", body.dig("lease", "holder")
    refute body["lease"].key?("token")
    text = mcp_rpc("tools/call", { name: "cluster", arguments: {} }).dig("result", "content", 0, "text")
    assert_includes text, '"holder": "node-b"'
    refute_includes text, "secret-token"
  ensure
    @rt[:store].lease_release!("secret-token")
  end

  def test_legacy_redirect_off_by_default_and_on_when_configured
    res = @mock.get("/health", "HTTP_HOST" => "standby.example.com")
    assert_equal 200, res.status, "no redirect without LEGACY_REDIRECT_*"
    ENV["LEGACY_REDIRECT_FROM"] = "standby."
    ENV["LEGACY_REDIRECT_TO"] = "sentinel."
    res = @mock.get("/health?x=1", "HTTP_HOST" => "standby.example.com")
    assert_equal 308, res.status
    assert_equal "https://sentinel.example.com/health?x=1", res["location"]
    res = @mock.get("/health", "HTTP_HOST" => "other.example.com")
    assert_equal 200, res.status, "hosts not starting with FROM are untouched"
  ensure
    ENV.delete("LEGACY_REDIRECT_FROM")
    ENV.delete("LEGACY_REDIRECT_TO")
  end

  def test_api_sentinel_unknown_service_is_404
    res = @mock.get("/api/sentinel?service=ghost")
    assert_equal 404, res.status
    refute JSON.parse(res.body)["ok"]
  end

  def test_api_v1_status
    @rt[:loop].cycle!
    res = @mock.get("/api/v1/status")
    assert_equal 200, res.status
    assert_equal "no-store", res.headers["cache-control"]
    body = JSON.parse(res.body)
    assert body["ok"]
    assert_equal "node-b", body["node"]
    assert_equal %w[node-a node-b witness-1], body["hosts"].keys
    assert body["hosts"]["node-a"]["probes"].key?("ssh")
    svc = body["services"]["opencode"]
    assert_equal "node-a", svc["primary"]
    assert_equal "node-b", svc["standby"]
    assert svc["acting"]
    assert_equal "node-a", svc["mode"]
    assert svc.key?("gates")
    refute_match(/primary_|node_b_/, res.body.gsub(/"(node-a|node-b|witness-1)"/, ""), "neutral key names")
  end

  def test_api_promote_unknown_service
    res = JSON.parse(@mock.post("/api/promote", params: { "dry_run" => "true", "service" => "ghost" }).body)
    refute res["ok"]
    assert_match(/unknown service/, res["message"])
  end

  def test_api_hold_roundtrip
    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "true" }).body)
    assert res["ok"]
    assert res["hold"]
    assert_nil res["service"]
    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "false" }).body)
    assert res["ok"]
    refute res["hold"]
  end

  # A service hold is its own file; the node-wide hold covers the service but not the reverse.
  def test_api_hold_per_service_vs_node_wide
    svc = @rt[:state].for("opencode")
    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "true", "service" => "opencode" }).body)
    assert res["ok"]
    assert res["hold"]
    assert_equal "opencode", res["service"]
    assert svc.hold?
    refute @rt[:state].hold?, "service hold does not set the node-wide one"
    assert JSON.parse(@mock.get("/api/sentinel?service=opencode").body)["hold"]

    res = JSON.parse(@mock.post("/api/hold", params: { "on" => "false", "service" => "opencode" }).body)
    refute res["hold"]
    refute svc.hold?

    @mock.post("/api/hold", params: { "on" => "true" })
    assert svc.hold?, "node-wide hold folds into the service"
    assert JSON.parse(@mock.post("/api/hold", params: { "on" => "false", "service" => "opencode" }).body)["hold"],
           "releasing the service hold leaves the node-wide one"
    @mock.post("/api/hold", params: { "on" => "false" })
    refute svc.hold?

    res = @mock.post("/api/hold", params: { "on" => "true", "service" => "ghost" })
    assert_equal 404, res.status
    refute @rt[:state].hold?
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

  def test_api_events_and_transitions_filter_by_service
    @rt[:store].event!("decision", "svc-tagged", service: "opencode")
    @rt[:store].event!("decision", "untagged")
    id = @rt[:store].transition_start!(service: "opencode", action: "promote")
    @rt[:store].transition_end!(id, result: "ok", exit_code: 0)

    events = JSON.parse(@mock.get("/api/events?service=opencode&limit=1000").body)["events"]
    assert(events.any? { |e| e["message"] == "svc-tagged" })
    assert(events.all? { |e| e["service"] == "opencode" })

    trans = JSON.parse(@mock.get("/api/transitions?service=opencode").body)["transitions"]
    assert(trans.all? { |t| t["service"] == "opencode" })
    refute_empty trans

    assert_equal 404, @mock.get("/api/events?service=ghost").status
    assert_equal 404, @mock.get("/api/transitions?service=ghost").status
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

  def test_mcp_service_argument
    res = mcp_rpc("tools/list", {})
    promote = res.dig("result", "tools").find { |t| t["name"] == "promote" }
    assert promote.dig("inputSchema", "properties").key?("service")

    res = mcp_rpc("tools/call", { name: "cluster", arguments: { service: "opencode" } })
    body = JSON.parse(res.dig("result", "content", 0, "text"))
    assert_equal "opencode", body["service"]
    assert_equal ["opencode"], body["services"]
    assert body["acting"]

    res = mcp_rpc("tools/call", { name: "demote", arguments: { service: "ghost", dry_run: true } })
    assert_includes res.dig("result", "content", 0, "text"), "unknown service"
  end

  def test_mcp_status_hold_events_take_service
    schema = ->(name) { mcp_rpc("tools/list", {}).dig("result", "tools").find { |t| t["name"] == name }.dig("inputSchema", "properties") }
    %w[status hold events].each { |tool| assert schema.call(tool).key?("service"), "#{tool} takes service" }

    legacy = mcp_rpc("tools/call", { name: "status", arguments: {} }).dig("result", "content", 0, "text")
    explicit = mcp_rpc("tools/call", { name: "status", arguments: { service: "opencode" } }).dig("result", "content", 0, "text")
    assert_equal JSON.parse(legacy).keys, JSON.parse(explicit).keys
    assert_includes mcp_rpc("tools/call", { name: "status", arguments: { service: "ghost" } }).dig("result", "content", 0, "text"),
                    "unknown service"

    body = JSON.parse(mcp_rpc("tools/call", { name: "hold", arguments: { on: true, service: "opencode" } }).dig("result", "content", 0, "text"))
    assert body["hold"]
    assert_equal "opencode", body["service"]
    refute body["node_hold"]
    assert @rt[:state].for("opencode").hold?
    refute @rt[:state].hold?
    body = JSON.parse(mcp_rpc("tools/call", { name: "hold", arguments: { on: false, service: "opencode" } }).dig("result", "content", 0, "text"))
    refute body["hold"]
    body = JSON.parse(mcp_rpc("tools/call", { name: "hold", arguments: {} }).dig("result", "content", 0, "text"))
    refute body["hold"]
    assert_nil body["service"]

    @rt[:store].event!("decision", "mcp-svc", service: "opencode")
    @rt[:store].event!("decision", "mcp-none")
    rows = JSON.parse(mcp_rpc("tools/call", { name: "events", arguments: { service: "opencode", limit: 500 } }).dig("result", "content", 0, "text"))
    assert(rows.any? { |e| e["message"] == "mcp-svc" })
    assert(rows.all? { |e| e["service"] == "opencode" })
    assert_includes mcp_rpc("tools/call", { name: "events", arguments: { service: "ghost" } }).dig("result", "content", 0, "text"),
                    "unknown service"
  end

  def test_legacy_page_still_renders
    res = @mock.get("/")
    assert_equal 200, res.status
    assert_includes res.body, "sentinel"
    res = @mock.get("/health")
    assert JSON.parse(res.body)["ok"]
  end

  # The dashboard is generic: cards come from /api/v1/status, the markup names no host or service.
  def test_page_is_generic
    res = @mock.get("/")
    assert_includes res.body, 'id="service-card-tpl"'
    assert_includes res.body, 'id="t-confirm"'
    assert_includes res.body, 'id="services-row"'
    page = res.body.sub(/served by.*?<\/span>/m, "").sub(/<footer.*<\/footer>/m, "")
    refute_match(/\b(node-a|node-b|opencode|webui)\b/, page, "no hard-coded host or service names in the view")
    js = File.read(File.expand_path("../public/js/app.js", __dir__))
    refute_match(/\b(node-a|node-b|webui)\b|'opencode'|"opencode"/, js, "no hard-coded host or service names in the dashboard script")
    refute_match(%r{/api/status\b}, js, "the page no longer polls the removed /api/status endpoint")
    assert_equal 404, @mock.get("/api/status").status, "the old probe page endpoint is gone"
    refute_match(/window\.(confirm|alert|prompt)\(/, js, "no native dialogs")
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
