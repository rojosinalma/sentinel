# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class TransportTest < Minitest::Test
  def test_in_process_routing
    calls = []
    t = Sentinel::Transport::InProcess.new(
      "http://a:4197" => ->(m, p, b) { calls << [m, p, b]; [200, '{"node":"a"}'] },
      "http://a:41970" => ->(_m, _p, _b) { [200, '{"node":"longest"}'] }
    )
    res = t.get("http://a:4197/peer/view")
    assert_equal 200, res[:code]
    assert_equal '{"node":"a"}', res[:body]
    assert_equal ["GET", "/peer/view", nil], calls.first

    res = t.get("http://a:41970/peer/view")
    assert_equal '{"node":"longest"}', res[:body], "longest prefix must win"

    res = t.post("http://a:4197/peer/lease", { "token" => "x" })
    assert_equal ["POST", "/peer/lease", { "token" => "x" }], calls.last

    assert Sentinel::Transport::InProcess.new({}).get("http://nope/x")[:error]
  end

  def test_in_process_callable_error
    t = Sentinel::Transport::InProcess.new("http://a" => ->(*) { raise "boom" })
    assert_match(/boom/, t.get("http://a/x")[:error])
  end

  def test_http_get_and_refused
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.readpartial(4096) rescue nil
      body = '{"ok":true}'
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
    t = Sentinel::Transport::Http.new(timeout: 2)
    res = t.get("http://127.0.0.1:#{port}/peer/view")
    assert_equal 200, res[:code]
    assert_equal '{"ok":true}', res[:body]
    thread.join

    server.close
    assert t.get("http://127.0.0.1:#{port}/peer/view")[:error]
  end
end
