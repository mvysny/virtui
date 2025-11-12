# frozen_string_literal: true

# All classes in this module have a [:value] function which calculates a value.
module Interpolator
  # Always provides given `value` {Object}.
  class Const < Data.define(:value)
  end

  # Returns `value_from` if current time is less than `time_from`; `value_from` if current time is
  # greater than `time_to`; a linear interpolation between `value_from` and `value_to` otherwise.
  #
  # Both `value_from` and `value_to` must be {Numeric} (ideally {Float}); both `time_from` and `time_from`
  # must be {Time}.
  class Linear < Data.define(:value_from, :value_to, :time_from, :time_to)
    def initialize(hash)
      super(hash)
      unless value_from.is_a?(Numeric) && value_to.is_a?(Numeric) && time_from.is_a?(Time) && time_to.is_a?(Time)
        raise 'invalid value type'
      end
      raise "#{time_from} can't be later than #{time_to}" if time_from > time_to
    end

    def self.from_now(value_from, value_to, duration_seconds)
      return Const.new(value_from) if value_from == value_to

      now = Time.now
      Linear.new(value_from, value_to, now, now + duration_seconds)
    end

    def value
      now = Time.now
      return value_from if now < time_from
      return value_to if now > time_to

      value_from + (value_to - value_from) * (now - time_from) / (time_to - time_from)
    end
  end
end
