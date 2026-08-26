# frozen_string_literal: true

# A stretch of time after some event during which a decision stays suppressed: {#active?}
# is `true` until the deadline passes and `false` for ever after. The one thing it adds
# over a bare `Time` is {#extended_by}'s never-shorten rule — the reason a deadline gets
# passed around as a value object rather than recomputed at each call site.
#
# There is no "no cooldown" state to nil-check: {ELAPSED} is one that is already over, so
# a caller can start from it and treat every instance the same.
#
#     back_off = Cooldown::ELAPSED
#     back_off = back_off.extended_by(10)   # armed for 10s, extending whatever was left
#     back_off.active?                      # => true
#     back_off.remaining.round(1)           # => 10.0
#
# Immutable, and reads the wall clock on every call — two calls a second apart disagree.
#
# Two things it deliberately is *not*. It is not an {Interpolator}: that module ramps
# numeric quantities for the emulator, and a latch needs {#remaining} and the never-shorten
# rule, neither of which is an interpolation. And it is not monotonic — wall-clock keeps it
# testable with Timecop, which is why {Virt::GuestAgent}, whose write-off must survive an
# NTP step, keeps its own `CLOCK_MONOTONIC` deadlines instead of using this.
#
# @!attribute [r] deadline
#   @return [Time] when the cooldown ends; in the past for one that already has
class Cooldown < Data.define(:deadline)
  # Validates the value object on construction.
  #
  # @raise [RuntimeError] if `deadline` is not a {Time}
  def initialize(hash)
    super
    raise "deadline must be a Time but was #{deadline.inspect}" unless deadline.is_a?(Time)
  end

  # A cooldown that has always been over — the starting value, and what {#extended_by}
  # measures the first extension against.
  ELAPSED = new(Time.at(0)).freeze

  # @param seconds [Numeric] how long from now the cooldown runs
  # @return [Cooldown] a cooldown ending `seconds` from now
  def self.of(seconds) = new(Time.now + seconds)

  # @return [Boolean] `true` while the deadline is still ahead
  def active? = Time.now < deadline

  # @return [Float] seconds left, `0.0` once elapsed — never negative, so it is safe to
  #   print without checking {#active?} first
  def remaining = [deadline - Time.now, 0.0].max

  # Pushes the deadline out to `seconds` from now, *unless* that would bring it closer:
  # a caller arming a short cooldown must never cut short a longer one already running.
  #
  # @param seconds [Numeric] how long from now the extended cooldown should run
  # @return [Cooldown] this one, or a longer one — never a shorter one
  def extended_by(seconds)
    extended = Cooldown.of(seconds)
    extended.deadline > deadline ? extended : self
  end
end
