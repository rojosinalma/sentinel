# frozen_string_literal: true

module Sentinel
  # The four-way classification of one service on one host, exactly the bash classify(): the
  # service answers -> ok; no quorum -> this node may be the cut-off one, isolated; any host
  # probe up -> degraded; everything dark -> dead. Plus the multi-node agreement used on top of
  # gossip.
  module Classifier
    DOWN = %i[degraded dead].freeze

    module_function

    # service_state: the host's "up …" | "down" | nil string for the service being judged.
    def classify(service_state, view, quorum:)
      return :ok if service_state.to_s.start_with?("up")
      return :isolated unless quorum == "up"

      view.any_host_probe_up? ? :degraded : :dead
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
