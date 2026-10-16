# frozen_string_literal: true

# Load order per docs/SDD.md (each module only depends on the ones before it).
%w[
  config workers store state
  probes/http probes/tcp probes/icmp probes host_view classifier
  transport gossip lease routes
  hooks decider loop
  status actions mcp_server boot
].each do |name|
  path = File.expand_path("sentinel/#{name}.rb", __dir__)
  require path if File.exist?(path)
end
