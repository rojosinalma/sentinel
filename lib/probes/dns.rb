# frozen_string_literal: true

module Probes
  # Where a public hostname points, via DNS-over-HTTPS (no CF token in this app). A proxied CF
  # record hides its CNAME and answers with CF edge A records, in which case the target is taken
  # from the sentinel's `mode` (node-a's tunnel while mode=node-a, node-b's while mode=node-b).
  module Dns
    module_function

    def call(name, sentinel_mode: nil)
      base = ::Config.fetch("DOH_URL")
      cname = Http.json("#{base}?name=#{name}&type=CNAME", headers: { "accept" => "application/dns-json" }, tag: "doh")
      return { name: name, state: "error", error: cname[:error] } if cname[:error]

      answers = Array(cname.dig(:json, "Answer")).select { |a| a["type"] == 5 }
      if answers.any?
        target = answers.first["data"].to_s.chomp(".")
        return { name: name, state: "cname", target: target, points_to: tunnel_owner(target) }
      end

      a = Http.json("#{base}?name=#{name}&type=A", headers: { "accept" => "application/dns-json" }, tag: "doh")
      ips = Array(a.dig(:json, "Answer")).select { |r| r["type"] == 1 }.map { |r| r["data"] }
      return { name: name, state: "missing", error: "no CNAME or A record" } if ips.empty?

      { name: name, state: "proxied", ips: ips, points_to: sentinel_mode, inferred: true }
    end

    def tunnel_owner(target)
      id = target.delete_suffix(".cfargotunnel.com")
      return "node-a" if id == ::Config.fetch("NODE_A_TUNNEL_ID") && !id.empty?
      return "node-b" if id == ::Config.fetch("NODE_B_TUNNEL_ID") && !id.empty?

      nil
    end
  end
end
