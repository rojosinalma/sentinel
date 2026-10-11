# frozen_string_literal: true

require "json"
require "time"

module Sentinel
  # Each node publishes what it sees (/peer/view) and polls the others. Agreement is computed
  # over the fresh views only: a stale or unreachable peer simply has no vote. Views survive a
  # restart through the store, but freshness still applies, so a reboot never acts on old news.
  class Gossip
    def initialize(cluster:, transport:, store:, stale_s:, now: -> { Time.now })
      @cluster = cluster
      @transport = transport
      @store = store
      @stale_s = stale_s
      @now = now
      @reachable = [].freeze
      @mutex = Mutex.new
    end

    # One parallel fetch of every peer's /peer/view. Bodies whose "node" does not match the
    # peer they came from are dropped (a misrouted or cloned sentinel must not vote as someone
    # else). Updates the reachable set the quorum check reads.
    def poll!
      jobs = @cluster.peers.to_h do |peer|
        [peer.name, -> { @transport.get("#{peer.sentinel_url}/peer/view") }]
      end
      results = Workers.parallel(jobs, timeout: @stale_s)
      reachable = []
      results.each do |name, res|
        next unless res.is_a?(Hash) && res[:code] == 200

        body = parse(res[:body])
        unless body && body["node"] == name
          $log.warn "[gossip] view from #{name} claims node=#{body && body['node'].inspect}, dropped"
          next
        end
        @store.peer_view_put!(name, at: body["at"], body: res[:body], now: @now.call)
        reachable << name
      end
      @mutex.synchronize { @reachable = reachable.freeze }
      nil
    end

    # Fresh peer views only: {"node" => Hash}.
    def views
      cutoff = @now.call - @stale_s
      @store.peer_views.each_with_object({}) do |row, out|
        next if row[:node] == @cluster.node_name
        next unless row[:received_at] && Time.iso8601(row[:received_at]) >= cutoff

        body = parse(row[:body])
        out[row[:node]] = body if body
      end
    end

    def reachable_peers
      fresh = views.keys
      @mutex.synchronize { @reachable }.select { |n| fresh.include?(n) }
    end

    # This node plus the peers it can see: a majority means this node is allowed to believe
    # its own eyes. Without it the node is the isolated one and never acts.
    def quorum? = reachable_peers.size + 1 >= @cluster.majority

    def classes_for(host_name, local_class)
      classes = { @cluster.node_name => local_class }
      views.each do |node, body|
        cls = body.dig("hosts", host_name, "class")
        classes[node] = cls.to_sym if cls
      end
      classes
    end

    def agreed_class(host_name, local_class)
      Classifier.agree(classes_for(host_name, local_class), majority: @cluster.majority)
    end

    # The replicated primary: newest primary_at wins across fresh views and the local store.
    def primary(service_name)
      candidates = []
      views.each_value do |body|
        host = body.dig("primary", service_name)
        at = body.dig("primary_at", service_name)
        candidates << [Time.iso8601(at), host] if host && at
      end
      if (host = @store.get("primary.#{service_name}")) && (at = @store.get("primary_at.#{service_name}"))
        candidates << [Time.iso8601(at), host]
      end
      candidates.max_by(&:first)&.last
    end

    # The body /peer/view serves. seq is monotonic and survives restarts via the store.
    def local_view(hosts:, classes:, primary:, primary_at:, hold:, transition:, quorum:)
      seq = @store.get("gossip.seq").to_i + 1
      @store.set("gossip.seq", seq)
      {
        "node" => @cluster.node_name,
        "at" => iso(@now.call),
        "seq" => seq,
        "primary" => primary,
        "primary_at" => primary_at,
        "hosts" => hosts.to_h do |name, view|
          [name, view.to_h.except("name").merge("class" => classes[name].to_s)]
        end,
        "quorum" => quorum,
        "reachable_peers" => reachable_peers,
        "hold" => hold,
        "transition" => transition,
        "lease" => current_lease
      }
    end

    private

    def current_lease
      @cluster.services.each_key do |service|
        row = @store.lease_current(service, now: @now.call)
        next unless row

        return { "service" => row[:service], "holder" => row[:holder],
                 "action" => row[:action], "expires_at" => row[:expires_at] }
      end
      nil
    end

    def parse(json)
      body = JSON.parse(json)
      body.is_a?(Hash) ? body : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    def iso(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
