# frozen_string_literal: true

# Load order per docs/architecture.md. Tolerant of files that other phase-1 agents have not
# landed yet; once phase 1 is complete every file exists and the glob guard is a no-op.
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
