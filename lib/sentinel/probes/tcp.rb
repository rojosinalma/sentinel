# frozen_string_literal: true

require "socket"

module Sentinel
  module Probes
    # Bounded TCP connect, the Ruby equivalent of the bash `/dev/tcp` probe.
    module Tcp
      module_function

      def open?(host, port, timeout:)
        Socket.tcp(host, port, connect_timeout: timeout, &:close)
        true
      rescue StandardError
        false
      end
    end
  end
end
