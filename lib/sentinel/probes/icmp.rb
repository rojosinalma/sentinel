# frozen_string_literal: true

module Sentinel
  module Probes
    # One echo request via iputils (unprivileged ICMP datagram socket), like the bash icmp_up.
    module Icmp
      module_function

      def up?(host, timeout:)
        system("ping", "-c", "1", "-W", timeout.to_s, "-q", host,
               out: File::NULL, err: File::NULL) == true
      rescue StandardError
        false
      end
    end
  end
end
