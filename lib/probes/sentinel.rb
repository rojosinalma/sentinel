# frozen_string_literal: true

module Probes
  # The sentinel on tiny (GET /status). Its document is passed through verbatim under `doc`, so new
  # fields the sentinel grows show up without a change here; the page reads what it knows.
  module Sentinel
    module_function

    def call(url)
      return { state: "unconfigured" } if url.to_s.empty?

      res = Http.json(url, tag: "sentinel")
      return { state: "unreachable", url: url, error: res[:error], ms: res[:ms] } if res[:error]
      return { state: "unreachable", url: url, error: "HTTP #{res[:code]}", ms: res[:ms] } unless res[:code] == 200 && res[:json].is_a?(Hash)

      { state: "ok", url: url, ms: res[:ms], doc: res[:json] }
    end
  end
end
