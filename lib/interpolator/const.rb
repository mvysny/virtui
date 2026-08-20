# frozen_string_literal: true

module Interpolator
  # An {Interpolator} whose `value` never changes — the degenerate case, for when there is
  # nothing to animate.
  #
  # @!attribute [r] value
  #   @return [Numeric] the constant value returned for any "now"
  class Const < Data.define(:value)
  end
end
