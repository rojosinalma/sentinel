require "dotenv"
Dotenv.load(File.expand_path(".env", __dir__))

require "rack/unreloader"
require_relative "lib/logger"

dev = ENV["RACK_ENV"] == "development"
# Only the app's own constants are unloaded; gems would otherwise be torn down on reload.
RELOADABLE = %w[Roda Probes Status].freeze
Unreloader = Rack::Unreloader.new(subclasses: RELOADABLE, reload: dev, logger: ($log if dev)) { App }
Unreloader.require(File.expand_path("app.rb", __dir__)) { "App" }

$log.info "[boot] standby-status #{ENV.fetch('APP_VERSION', 'dev')} on #{ENV.fetch('HOST_NAME', '?')} (#{dev ? 'development' : 'production'})"
run(dev ? Unreloader : App.freeze.app)
