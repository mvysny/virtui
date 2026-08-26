# frozen_string_literal: true

module Virt
  class BallooningVM
    # Vetoes lowering a VM's memory for a while after {BallooningVM} last touched it, or
    # after it started. The one input that observes nothing about the guest: it is
    # {BallooningVM}'s memory of *its own* actions, which is why it is the only one with a
    # method the framework calls to arm it.
    #
    # Asymmetric on purpose, and the asymmetry is the whole point of the class: raises
    # ignore it entirely, because a VM that needs RAM needs it whatever we did a second ago,
    # while a VM with RAM to spare can give it back at leisure.
    #
    # UI-thread-confined, like its owner.
    class BackOffShrinkVetoer
      def initialize
        @veto = Cooldown::ELAPSED
      end

      # Vetoes lowering for `seconds` from now — extending an active veto, never cutting one
      # short ({Cooldown#extended_by}).
      #
      # @param seconds [Numeric] how long to stay off this VM
      # @return [void]
      def arm(seconds)
        @veto = @veto.extended_by(seconds)
      end

      # Nothing about the guest bears on this one; it is here so the framework can feed
      # every input the same way.
      #
      # @param _vm_cache [Cache::VMCache, nil] ignored
      # @return [void]
      def observe(_vm_cache) = nil

      # @return [String, nil] why this VM's memory must not be lowered right now, phrased to
      #   follow a colon; `nil` once the back-off lapses
      def veto_reason
        return nil unless @veto.active?

        "backing off for #{@veto.remaining.round(1)}s"
      end

      # Drops the veto, so the next tick may lower memory at once. Called when the user
      # changes the ballooning setting by hand — they want to see the effect now.
      #
      # @return [void]
      def forget
        @veto = Cooldown::ELAPSED
      end
    end
  end
end
