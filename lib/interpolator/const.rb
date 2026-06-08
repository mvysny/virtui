# frozen_string_literal: true

module Interpolator
  # Always provides given `value` {Object}.
  #
  # Immutable, thread-safe.
  class Const < Data.define(:value)
  end
end
