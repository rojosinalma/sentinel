# frozen_string_literal: true

require "sequel"
require "json"
require "fileutils"
require "time"

module Sentinel
  # SQLite event store: everything the loop sees and decides, plus the replicated cluster
  # state and the lease table. Migrations are additive and run on every open.
  class Store
    class LeaseHeld < StandardError; end

    def self.open(path, node: nil)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      new(Sequel.sqlite(path, timeout: 5000), node: node)
    end

    def self.memory(node: nil) = new(Sequel.sqlite, node: node)

    attr_accessor :node_name

    def initialize(db, node: nil)
      @db = db
      @node_name = node
      @db.pragma_set(:journal_mode, "wal") rescue nil
      migrate!
    end

    # ---------------------------------------------------------------- events

    def event!(kind, message, level: "info", host: nil, service: nil, node: @node_name, **data)
      id = @db[:events].insert(
        at: iso_now, node: node, kind: kind.to_s, level: level, host: host,
        service: service, message: message, data: data.empty? ? nil : JSON.generate(data)
      )
      log_line = "[event] #{kind}: #{message}"
      case level
      when "error" then $log.error(log_line)
      when "warn" then $log.warn(log_line)
      else $log.info(log_line)
      end
      id
    end

    def events(limit: 200, since: nil, kind: nil, service: nil)
      ds = @db[:events].reverse(:id).limit(limit)
      if since
        cutoff = iso(since)
        ds = ds.where { at >= cutoff }
      end
      ds = ds.where(kind: kind.to_s) if kind
      ds = ds.where(service: service.to_s) if service
      ds.all.map { |row| row_with_data(row) }
    end

    # ---------------------------------------------------------------- transitions

    def transition_start!(service:, action:, node: @node_name, log_file: nil)
      @db[:transitions].insert(service: service, action: action, started_at: iso_now,
                               node: node, log_file: log_file)
    end

    def transition_end!(id, result:, exit_code: nil, **data)
      @db[:transitions].where(id: id).update(
        finished_at: iso_now, result: result, exit_code: exit_code,
        data: data.empty? ? nil : JSON.generate(data)
      )
      nil
    end

    def transitions(service: nil, limit: 50)
      ds = @db[:transitions].reverse(:id).limit(limit)
      ds = ds.where(service: service) if service
      ds.all.map { |row| row_with_data(row) }
    end

    # ---------------------------------------------------------------- cluster state

    def get(key)
      row = @db[:cluster_state].where(key: key.to_s).first
      row && row[:value]
    end

    def set(key, value)
      @db[:cluster_state].insert_conflict(target: :key, update: { value: value.to_s, updated_at: iso_now })
                         .insert(key: key.to_s, value: value.to_s, updated_at: iso_now)
      value
    end

    # ---------------------------------------------------------------- leases

    # Grants (or extends, for the same holder) the service lease. An unexpired lease held by
    # someone else raises LeaseHeld — that is the whole point of the table.
    def lease_grant!(service:, holder:, action:, token:, ttl_s:, granted_by: nil, now: Time.now)
      granted_by = Array(granted_by).join(",") if granted_by.is_a?(Array)
      @db.transaction do
        current = lease_current(service, now: now)
        if current && current[:holder] != holder
          raise LeaseHeld, "lease for #{service} held by #{current[:holder]} until #{current[:expires_at]}"
        end

        expires = iso(now + ttl_s)
        if current
          @db[:leases].where(id: current[:id]).update(expires_at: expires, token: token, action: action,
                                                      granted_by: granted_by)
          current.merge(expires_at: expires, token: token, action: action, granted_by: granted_by)
        else
          id = @db[:leases].insert(service: service, holder: holder, action: action, token: token,
                                   granted_at: iso(now), expires_at: expires, granted_by: granted_by)
          @db[:leases].where(id: id).first
        end
      end
    end

    def lease_current(service, now: Time.now)
      cutoff = iso(now)
      @db[:leases].where(service: service).where { expires_at > cutoff }.reverse(:id).first
    end

    def lease_release!(token)
      @db[:leases].where(token: token).delete
      nil
    end

    # ---------------------------------------------------------------- peer views

    def peer_view_put!(node, at:, body:, now: Time.now)
      received = iso(now)
      @db[:peer_views].insert_conflict(target: :node, update: { at: at, received_at: received, body: body })
                      .insert(node: node, at: at, received_at: received, body: body)
      nil
    end

    # Array of {node:, at:, received_at:, body:}; body stays a JSON string.
    def peer_views = @db[:peer_views].order(:node).all

    # ---------------------------------------------------------------- maintenance

    def prune!(keep_days:)
      cutoff = iso(Time.now - (keep_days * 86_400))
      now = iso_now
      events_n = @db[:events].where { at < cutoff }.delete
      trans_n = @db[:transitions].where { started_at < cutoff }.delete
      leases_n = @db[:leases].where { expires_at < now }.delete
      { events: events_n, transitions: trans_n, leases: leases_n }
    end

    def db = @db

    private

    def iso_now = iso(Time.now)
    def iso(time) = time.is_a?(Time) ? time.utc.strftime("%Y-%m-%dT%H:%M:%SZ") : time.to_s

    def row_with_data(row)
      row[:data] = row[:data] ? JSON.parse(row[:data]) : nil
      row
    end

    def migrate!
      @db.create_table?(:events) do
        primary_key :id
        String :at, null: false
        String :node
        String :kind, null: false
        String :level, null: false, default: "info"
        String :host
        String :service
        String :message
        String :data
        index :at
        index :kind
      end
      @db.create_table?(:transitions) do
        primary_key :id
        String :service, null: false
        String :action, null: false
        String :started_at, null: false
        String :finished_at
        String :result
        Integer :exit_code
        String :log_file
        String :node
        String :data
      end
      @db.create_table?(:leases) do
        primary_key :id
        String :service, null: false
        String :holder, null: false
        String :action
        String :token, null: false
        String :granted_at, null: false
        String :expires_at, null: false
        String :granted_by
        index :service
        index :token
      end
      @db.create_table?(:cluster_state) do
        String :key, primary_key: true
        String :value
        String :updated_at
      end
      @db.create_table?(:peer_views) do
        String :node, primary_key: true
        String :at
        String :received_at
        String :body
      end
      @db.create_table?(:settings) do
        String :key, primary_key: true
        String :value
      end
    end
  end
end
