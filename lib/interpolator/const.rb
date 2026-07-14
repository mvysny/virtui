# frozen_string_literal: true

module Interpolator
  # An {Interpolator} whose `value` never changes — it always returns the wrapped `value`.
  #
  # Used as the degenerate case when there is nothing to animate (see
  # {Interpolator::Linear.from_now}, which returns a `Const` when start equals end).
  #
  # @!attribute [r] value
  #   @return [Numeric] the constant value returned for any "now"
  class Const < Data.define(:value)
  end
end
