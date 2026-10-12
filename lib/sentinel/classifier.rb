# frozen_string_literal: true

module Sentinel
  # The four-way classification of one service on one host, exactly the bash classify(): the
  # service answers -> ok; no quorum -> this node may be the cut-off one, isolated; any host
  # probe up -> degraded; everything dark -> dead. Plus the multi-node agreement used on top of
  # gossip. A standby whose service is deliberately stopped (the other host is primary) is
  # `standby`, not degraded: the host is fine, the service is meant to be down there.
  module Classifier
    DOWN = %i[degraded dead].freeze

    module_function

    # service_state: the host's "up …" | "down" | nil string for the service being judged.
    # standing_by: the host is the service's standby and is not the current primary.
    def classify(service_state, view, quorum:, standing_by: false)
      return :ok if service_state.to_s.start_with?("up")
      return :isolated unless quorum == "up"
      return :dead unless view.any_host_probe_up?

      standing_by ? :standby : :degraded
    end

    # classes: {"node" => :sym} from every fresh view (self included). A host is DEAD only when
    # a majority says dead; a majority saying "down at all" without majority-dead is degraded.
    def agree(classes, majority:)
      dead = classes.values.count(:dead)
      down = classes.values.count { |c| DOWN.include?(c) }
      return :dead if dead >= majority
      return :degraded if down >= majority

      :ok
    end
  end
end
