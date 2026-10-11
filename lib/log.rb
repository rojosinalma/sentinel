# frozen_string_literal: true

require "logger"

$stdout.sync = true

$log ||= Logger.new($stdout, level: ENV.fetch("LOG_LEVEL", "info")).tap do |logger|
  logger.formatter = proc do |severity, time, _prog, msg|
    "#{time.strftime('%Y-%m-%d %H:%M:%S')} #{severity.ljust(5)} #{msg}\n"
  end
end
