# frozen_string_literal: true

module Probes
  # webui: GET /health → {status:"ok", webuiVersion, openCodeRunning, isOpenCodeReady}.
  module Webui
    module_function

    def call(url)
      return { state: "unconfigured" } if url.to_s.empty?

      res = Http.json("#{url.chomp('/')}/health", tag: "webui")
      return { state: "down", url: url, error: res[:error], ms: res[:ms] } if res[:error]
      return { state: "down", url: url, error: "HTTP #{res[:code]}", ms: res[:ms] } unless res[:code] == 200

      doc = res[:json] || {}
      {
        state: doc["status"] == "ok" ? "up" : "degraded",
        url: url,
        version: doc["webuiVersion"],
        opencode_ready: doc["isOpenCodeReady"],
        ms: res[:ms]
      }
    end
  end
end
