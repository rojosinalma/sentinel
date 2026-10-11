# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Sentinel
  # The majority lease: before any promote/demote the acting node asks every peer for a grant
  # and proceeds only when grants + its own vote reach the majority. Every node persists what it
  # granted, so two would-be actors cannot both get a majority within one TTL.
  class Lease
    class Denied < StandardError
      attr_reader :reasons

      def initialize(reasons)
        @reasons = reasons
        super("lease denied: #{reasons.join('; ')}")
      end
    end

    class Expired < StandardError; end

    Grant = Struct.new(:service, :action, :token, :expires_at, :granted_by, keyword_init: true)

    def initialize(cluster:, transport:, store:, ttl_s:, now: -> { Time.now })
      @cluster = cluster
      @transport = transport
      @store = store
      @ttl_s = ttl_s
      @now = now
    end

    # ---------------------------------------------------------------- client side

    def acquire!(service:, action:)
      token = SecureRandom.uuid
      body = request_body(service, action, token)
      granted, reasons = ask_peers(@cluster.peers, body)

      unless granted.size + 1 >= @cluster.majority
        @store.event!("lease.deny", "no majority for #{action} of #{service}: #{reasons.join('; ')}",
                      level: "warn", service: service)
        raise Denied, reasons
      end

      begin
        row = @store.lease_grant!(service: service, holder: @cluster.node_name, action: action,
                                  token: token, ttl_s: @ttl_s, granted_by: granted, now: @now.call)
      rescue Store::LeaseHeld => e
        raise Denied, [e.message]
      end
      @store.event!("lease.grant", "majority lease for #{action} of #{service} (granted by #{granted.join(', ')})",
                    service: service, token: token)
      Grant.new(service: service, action: action, token: token,
                expires_at: row[:expires_at], granted_by: granted).freeze
    end

    # Renewal goes to the peers that granted; losing the majority mid-action aborts the action.
    def renew!(grant)
      peers = @cluster.peers.select { |p| grant.granted_by.include?(p.name) }
      body = request_body(grant.service, grant.action, grant.token)
      granted, reasons = ask_peers(peers, body)
      unless granted.size + 1 >= @cluster.majority
        raise Expired, "lease renewal lost majority: #{reasons.join('; ')}"
      end

      row = @store.lease_grant!(service: grant.service, holder: @cluster.node_name, action: grant.action,
                                token: grant.token, ttl_s: @ttl_s, granted_by: granted, now: @now.call)
      Grant.new(service: grant.service, action: grant.action, token: grant.token,
                expires_at: row[:expires_at], granted_by: granted).freeze
    end

    def release!(grant)
      @cluster.peers.select { |p| grant.granted_by.include?(p.name) }.each do |peer|
        @transport.post("#{peer.sentinel_url}/peer/lease/release", { "token" => grant.token })
      end
      @store.lease_release!(grant.token)
      nil
    end

    # ---------------------------------------------------------------- server side

    # -> [status, body_hash]; wired to POST /peer/lease by the app.
    def handle_request(body)
      service, holder, action, token = body.values_at("service", "holder", "action", "token")
      ttl = body["ttl_s"] || @ttl_s

      unless @cluster.services.key?(service)
        return deny(service, holder, action, "unknown service #{service.inspect}", status: 400)
      end
      unless holder == @cluster.service(service).standby
        return deny(service, holder, action, "holder #{holder} is not the standby of #{service}")
      end

      begin
        row = @store.lease_grant!(service: service, holder: holder, action: action,
                                  token: token, ttl_s: ttl, now: @now.call)
      rescue Store::LeaseHeld => e
        return deny(service, holder, action, e.message)
      end

      @store.event!("lease.grant", "granted #{action} of #{service} to #{holder}",
                    service: service, token: token)
      [200, { ok: true, expires_at: row[:expires_at] }]
    end

    def handle_release(body)
      @store.lease_release!(body["token"])
      [200, { ok: true }]
    end

    private

    def request_body(service, action, token)
      { "service" => service, "holder" => @cluster.node_name, "action" => action,
        "ttl_s" => @ttl_s, "token" => token }
    end

    # -> [granted_names, reasons]
    def ask_peers(peers, body)
      jobs = peers.to_h { |peer| [peer.name, -> { @transport.post("#{peer.sentinel_url}/peer/lease", body) }] }
      results = Workers.parallel(jobs, timeout: @ttl_s / 2.0)
      granted = []
      reasons = []
      results.each do |name, res|
        if res.is_a?(Hash) && res[:code] == 200 && (JSON.parse(res[:body])["ok"] rescue false)
          granted << name
        else
          reasons << "#{name}: #{reason_of(res)}"
        end
      end
      [granted, reasons]
    end

    def reason_of(res)
      return "no answer" unless res.is_a?(Hash)
      return res[:error] if res[:error]
      return res[:state] if res[:state]

      message = (JSON.parse(res[:body])["message"] rescue nil)
      "#{res[:code]}#{message ? ": #{message}" : ''}"
    end

    def deny(service, holder, action, message, status: 409)
      @store.event!("lease.deny", "denied #{action} of #{service} to #{holder}: #{message}",
                    level: "warn", service: service)
      [status, { ok: false, message: message }]
    end
  end
end
