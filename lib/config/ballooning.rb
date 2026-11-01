# frozen_string_literal: true

class Config
  # The `[ballooning]` table: when a guest grows and shrinks, and how far it may shrink.
  #
  # @!attribute [r] raise_at_percent
  #   @return [Integer] guest memory use, omitting cache, in percent, at or above which the guest
  #     is grown ({Virt::BallooningVM::MemLevelRaiseVoter}). 65 leaves a 35% reserve, where MoM,
  #     Hyper-V and K8s VPA all use 15-20%. Not `100 - vm.swappiness`: swappiness weights the
  #     anon LRU against the file LRU once reclaim has *already* started and says nothing about
  #     when it starts. A guest at 61% was measured holding 2 GiB of swap
  #     (`design/ideas/swap-despite-ballooning.md`).
  # @!attribute [r] shrink_at_percent
  #   @return [Integer] guest memory use, in percent, at or below which the guest is shrunk
  #     ({Virt::BallooningVM::MemLevelShrinkVoter}). The 10-point gap to 65 is a deadband, and
  #     narrower than it looks: a 30% raise takes a guest reading 65% straight down to 50%, five
  #     points under 55, so a raise is followed by a shrink once the back-off lapses
  #     (`design/ideas/swap-despite-ballooning.md` has the arithmetic).
  # @!attribute [r] min_actual_gib
  #   @return [Integer] the floor no guest is shrunk below, in GiB: 8 is a healthy desktop
  #     guest. A VM configured with less than twice this floors at half its maximum instead
  #     ({Virt::BallooningVM#floor}).
  class Ballooning < Data.define(:raise_at_percent, :shrink_at_percent, :min_actual_gib)
    extend Typemap::Constrain

    constrain :raise_at_percent, :shrink_at_percent, in: 1..100
    constrain :min_actual_gib, in: (1..)

    # @param raise_at_percent [Integer]
    # @param shrink_at_percent [Integer]
    # @param min_actual_gib [Integer]
    def initialize(raise_at_percent: 65, shrink_at_percent: 55, min_actual_gib: 8) = super

    # Typemap calls this on every load.
    #
    # @return [void]
    # @raise [RuntimeError] unless {#raise_at_percent} is above {#shrink_at_percent}: at or
    #   below it both voters fire on one sample and the VM hunts (`D_ballooning_voters`)
    def validate
      return if raise_at_percent > shrink_at_percent

      raise "raise_at_percent (#{raise_at_percent}) must be above shrink_at_percent (#{shrink_at_percent})"
    end
  end
end
