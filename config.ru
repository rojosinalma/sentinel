require "dotenv"
Dotenv.load(File.expand_path(".env", __dir__))

require "rack/unreloader"
require_relative "lib/log"

dev = ENV["RACK_ENV"] == "development"
# Only the app's own constants are unloaded; gems would otherwise be torn down on reload.
RELOADABLE = %w[Roda].freeze
Unreloader = Rack::Unreloader.new(subclasses: RELOADABLE, reload: dev, logger: ($log if dev)) { App }
Unreloader.require(File.expand_path("app.rb", __dir__)) { "App" }

# The sentinel core loads once (never reloaded) and runs only when NODE_NAME is set.
require_relative "lib/sentinel"
if Sentinel.enabled?
  Sentinel.boot!
  Sentinel.start_loop!
end

$log.info "[boot] sentinel #{ENV.fetch('APP_VERSION', 'dev')} on #{ENV.fetch('HOST_NAME', '?')} (#{dev ? 'development' : 'production'})"
run(dev ? Unreloader : App.freeze.app)
