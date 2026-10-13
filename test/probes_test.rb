# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class ProbesTest < Minitest::Test
  FakeHost = Sentinel::Config::Host

  def test_tcp_open_and_closed
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    assert Sentinel::Probes::Tcp.open?("127.0.0.1", port, timeout: 1)
    server.close
    refute Sentinel::Probes::Tcp.open?("127.0.0.1", port, timeout: 1)
  end

  def test_http_get_ok
    with_http_server(200, '{"version":"9.9.9"}') do |port|
      res = Sentinel::Probes::Http.get("http://127.0.0.1:#{port}/api/info", timeout: 2)
      assert_equal 200, res[:code]
      assert_match(/9\.9\.9/, res[:body])
      assert_kind_of Integer, res[:ms]
    end
  end

  def test_http_get_refused
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    res = Sentinel::Probes::Http.get("http://127.0.0.1:#{port}/", timeout: 1)
    assert res[:error]
  end

  def test_host_view_assembly
    ssh_server = TCPServer.new("127.0.0.1", 0)
    ssh_port = ssh_server.addr[1]
    closed = TCPServer.new("127.0.0.1", 0)
    closed_port = closed.addr[1]
    closed.close

    with_http_server(200, '{"version":"9.9.9"}') do |svc_port|
      host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "",
                          role: :member, probes: { ssh: ssh_port, traefik: closed_port })
      view = Sentinel::Probes.host(host, service_urls: { "opencode" => "http://127.0.0.1:#{svc_port}/api/info" },
                                         timeout: 1)
      assert_equal "up 9.9.9", view.service_state("opencode")
      assert_equal "up", view.ssh
      assert_equal "down", view.traefik
      assert_nil view.icmp
      assert view.service_up?("opencode")
      assert view.any_host_probe_up?
      assert_equal "9.9.9", view.version("opencode")
    end
  ensure
    ssh_server&.close
  end

  def test_service_401_is_up
    with_http_server(401, "unauthorized") do |port|
      host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
      view = Sentinel::Probes.host(host, service_urls: { "opencode" => "http://127.0.0.1:#{port}/api/info" }, timeout: 1)
      assert_equal "up auth?", view.service_state("opencode")
      assert view.service_up?("opencode")
      assert_nil view.version("opencode")
    end
  end

  def test_service_down_when_no_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
    view = Sentinel::Probes.host(host, service_urls: { "opencode" => "http://127.0.0.1:#{port}/api/info" }, timeout: 1)
    assert_equal "down", view.service_state("opencode")
    refute view.service_up?("opencode")
    refute view.any_host_probe_up?
  end

  def test_two_services_probed_in_one_pass
    closed = TCPServer.new("127.0.0.1", 0)
    closed_port = closed.addr[1]
    closed.close
    with_http_server(200, '{"version":"1.2.3"}') do |up_port|
      host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
      view = Sentinel::Probes.host(host, service_urls: { "a" => "http://127.0.0.1:#{up_port}/api/info",
                                                         "b" => "http://127.0.0.1:#{closed_port}/api/info" },
                                         timeout: 1)
      assert_equal({ "a" => "up 1.2.3", "b" => "down" }, view.services)
    end
  end

  def test_no_services_gives_empty_map
    host = FakeHost.new(name: "witness-1", address: "127.0.0.1", sentinel_url: "", role: :witness, probes: {})
    assert_equal({}, Sentinel::Probes.host(host, timeout: 1).services)
  end

  # The fake server echoes the request head back, so the test sees Host and Authorization.
  def test_resolve_ip_keeps_the_url_host
    with_echo_server do |port|
      res = Sentinel::Probes::Http.get("http://sentinel-test.invalid:#{port}/health", resolve_ip: "127.0.0.1",
                                                                                      timeout: 2)
      assert_equal 200, res[:code], res.inspect
      assert_match(/^Host: sentinel-test\.invalid:#{port}/m, res[:body])
    end
  end

  def test_unresolvable_host_without_resolve_ip_errors
    res = Sentinel::Probes::Http.get("http://sentinel-test.invalid:1/health", timeout: 1)
    assert res[:error]
  end

  def test_per_service_credentials_and_headers
    with_echo_server do |port|
      host = FakeHost.new(name: "tiny", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
      a = Sentinel::Config::Probe.new(basic: %w[alice pw-a], headers: { "X-Probe" => "a" }, resolve: {})
      b = Sentinel::Config::Probe.new(basic: nil, headers: {}, resolve: { "tiny" => "127.0.0.1" })
      urls = { "a" => "http://127.0.0.1:#{port}/a", "b" => "http://sentinel-test.invalid:#{port}/b" }
      view = Sentinel::Probes.host(host, service_urls: urls, service_probes: { "a" => a, "b" => b }, timeout: 2)
      assert_equal "up ?", view.service_state("a")
      assert_equal "up ?", view.service_state("b"), "resolve ip for tiny made the bogus hostname reachable"

      heads = @requests.join
      assert_includes heads, "Authorization: Basic #{['alice:pw-a'].pack('m0')}"
      assert_includes heads, "X-Probe: a"
      assert_includes heads, "Host: sentinel-test.invalid:#{port}"
      refute_includes @requests.find { |h| h.start_with?("GET /b") }, "Authorization", "b has no credential"
    end
  end

  def test_quorum
    server = TCPServer.new("127.0.0.1", 0)
    open_port = server.addr[1]
    closed = TCPServer.new("127.0.0.1", 0)
    closed_port = closed.addr[1]
    closed.close

    assert_equal "up", Sentinel::Probes.quorum(["127.0.0.1:#{closed_port}", "127.0.0.1:#{open_port}"], timeout: 1)
    assert_equal "down", Sentinel::Probes.quorum(["127.0.0.1:#{closed_port}"], timeout: 1)
    assert_equal "n/a", Sentinel::Probes.quorum([], timeout: 1)
    assert_equal "n/a", Sentinel::Probes.quorum(nil, timeout: 1)
  ensure
    server&.close
  end

  private

  # Answers 200 with the request head as body and records every head in @requests.
  def with_echo_server
    @requests = []
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        head = client.readpartial(4096) rescue ""
        @requests << head
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{head.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{head}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield port
  ensure
    server&.close
    thread&.kill
  end

  # A one-shot HTTP server: accepts connections and writes a canned response.

  # tunables.probe_timeout_s: a service answering slower than the node-wide budget is still "up"
  # when its own budget allows it (2026-10-13: a loaded opencode at >3 s read as degraded).
  def test_per_service_timeout_lets_a_slow_service_pass
    with_slow_http_server(200, '{"version":"9.9.9"}', delay: 1.5) do |svc_port|
      host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "",
                          role: :member, probes: {})
      urls = { "opencode" => "http://127.0.0.1:#{svc_port}/api/info" }

      slow = Sentinel::Probes.host(host, service_urls: urls, timeout: 1)
      assert_equal "down", slow.service_state("opencode"), "node-wide 1 s budget: killed"
    end
    with_slow_http_server(200, '{"version":"9.9.9"}', delay: 1.5) do |svc_port|
      host = FakeHost.new(name: "silver", address: "127.0.0.1", sentinel_url: "",
                          role: :member, probes: {})
      urls = { "opencode" => "http://127.0.0.1:#{svc_port}/api/info" }
      view = Sentinel::Probes.host(host, service_urls: urls, timeout: 1,
                                         service_timeouts: { "opencode" => 4 })
      assert_equal "up 9.9.9", view.service_state("opencode"), "its own 4 s budget: up"
    end
  end

  def with_slow_http_server(code, body, delay:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        client.readpartial(4096) rescue nil
        sleep delay
        client.write("HTTP/1.1 #{code} OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield port
  ensure
    server&.close
    thread&.kill
  end

  def with_http_server(code, body)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        client.readpartial(4096) rescue nil
        reason = code == 200 ? "OK" : "Unauthorized"
        client.write("HTTP/1.1 #{code} #{reason}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield port
  ensure
    server&.close
    thread&.kill
  end
end
