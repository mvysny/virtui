# frozen_string_literal: true

module Interpolator
  # An {Interpolator} that ramps linearly from `value_from` to `value_to` over the time
  # window `time_from..time_to`.
  #
  # {#value} returns `value_from` before the window, `value_to` after it, and a linear
  # blend in between. Immutable and thread-safe (a frozen {Data} value object).
  #
  # @!attribute [r] value_from
  #   @return [Numeric] value returned at or before `time_from`
  # @!attribute [r] value_to
  #   @return [Numeric] value returned at or after `time_to`
  # @!attribute [r] time_from
  #   @return [Time] start of the interpolation window
  # @!attribute [r] time_to
  #   @return [Time] end of the interpolation window; must not precede `time_from`
  class Linear < Data.define(:value_from, :value_to, :time_from, :time_to)
    # Validates the value object on construction.
    #
    # @raise [RuntimeError] if `value_from`/`value_to` are not {Numeric} or
    #   `time_from`/`time_to` are not {Time}
    # @raise [RuntimeError] if `time_from` is later than `time_to`
    def initialize(hash)
      super
      raise 'invalid value type' unless value_from.is_a?(Numeric) && value_to.is_a?(Numeric) && time_from.is_a?(Time) && time_to.is_a?(Time)
      raise "#{time_from} can't be later than #{time_to}" if time_from > time_to
    end

    # Interpolates value from now for the duration of `duration_seconds`.
    # @param value_from [Numeric] start value
    # @param value_to [Numeric] end value
    # @param duration_seconds [Numeric] how long does it take to go from `value_from` to `value_to`
    # @return [Linear, Const] interpolation
    def self.from_now(value_from, value_to, duration_seconds)
      return Const.new(value_from) if value_from == value_to

      now = Time.now
      Linear.new(value_from, value_to, now, now + duration_seconds)
    end

    # Returns the current value
    # @return [Numeric] current value
    def value
      now = Time.now
      return value_from if now < time_from
      return value_to if now > time_to

      value_from + ((value_to - value_from) * (now - time_from) / (time_to - time_from))
    end
  end
end
