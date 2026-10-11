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
      host = FakeHost.new(name: "node-a", address: "127.0.0.1", sentinel_url: "",
                          role: :member, probes: { ssh: ssh_port, traefik: closed_port })
      view = Sentinel::Probes.host(host, service_url: "http://127.0.0.1:#{svc_port}/api/info", timeout: 1)
      assert_equal "up 9.9.9", view.opencode
      assert_equal "up", view.ssh
      assert_equal "down", view.traefik
      assert_nil view.icmp
      assert view.service_up?
      assert view.any_host_probe_up?
      assert_equal "9.9.9", view.version
    end
  ensure
    ssh_server&.close
  end

  def test_service_401_is_up
    with_http_server(401, "unauthorized") do |port|
      host = FakeHost.new(name: "node-a", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
      view = Sentinel::Probes.host(host, service_url: "http://127.0.0.1:#{port}/api/info", timeout: 1)
      assert_equal "up auth?", view.opencode
      assert view.service_up?
      assert_nil view.version
    end
  end

  def test_service_down_when_no_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    host = FakeHost.new(name: "node-a", address: "127.0.0.1", sentinel_url: "", role: :member, probes: {})
    view = Sentinel::Probes.host(host, service_url: "http://127.0.0.1:#{port}/api/info", timeout: 1)
    assert_equal "down", view.opencode
    refute view.service_up?
    refute view.any_host_probe_up?
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

  # A one-shot HTTP server: accepts connections and writes a canned response.
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
