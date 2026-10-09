# frozen_string_literal: true

module Probes
  # opencode server: GET /api/info with the Basic credential. 200 → up + version; 401 → up
  # (the server itself answered, the credential is just missing/wrong); anything else → down.
  module Opencode
    module_function

    def call(url)
      return { state: "unconfigured" } if url.to_s.empty?

      user = ::Config.fetch("OPENCODE_SERVER_USERNAME")
      pass = ::Config.fetch("OPENCODE_SERVER_PASSWORD")
      basic = pass.empty? ? nil : [user, pass]
      res = Http.json("#{url.chomp('/')}/api/info", basic: basic, tag: "opencode")
      return { state: "down", url: url, error: res[:error], ms: res[:ms] } if res[:error]

      case res[:code]
      when 200 then { state: "up", url: url, version: res.dig(:json, "version"), ms: res[:ms] }
      when 401 then { state: "up", url: url, version: nil, note: "401: credential rejected, server is answering", ms: res[:ms] }
      else { state: "down", url: url, error: "HTTP #{res[:code]}", ms: res[:ms] }
      end
    end
  end
end
