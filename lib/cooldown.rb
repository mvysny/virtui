# frozen_string_literal: true

# A stretch of time after some event during which a decision stays suppressed: {#active?}
# is `true` until the deadline passes and `false` for ever after. The one thing it adds
# over a bare deadline is {#extended_by}'s never-shorten rule — the reason it gets passed
# around as a value object rather than recomputed at each call site.
#
# There is no "no cooldown" state to nil-check: {ELAPSED} is one that is already over, so
# a caller can start from it and treat every instance the same.
#
#     back_off = Cooldown::ELAPSED
#     back_off = back_off.extended_by(10)   # armed for 10s, extending whatever was left
#     back_off.active?                      # => true
#     back_off.remaining.round(1)           # => 10.0
#
# Measured on {.now} — **uptime, not wall time**. Ten seconds means ten elapsed seconds
# whatever the wall clock does in between: an NTP correction, a timezone change and a
# manual `date` all leave a running cooldown exactly where it was. That is the contract,
# and it is why Timecop cannot move one — see DECISIONS.md D_cooldown_monotonic, and
# `Uptime.travel` in `spec/spec_helper.rb` for the counterpart specs use instead.
#
# Immutable, and reads the clock on every call — two calls a second apart disagree.
#
# Not an {Interpolator}: that module ramps numeric quantities for the emulator, and a latch
# needs {#remaining} and the never-shorten rule, neither of which is an interpolation.
#
# @!attribute [r] deadline
#   @return [Float] when the cooldown ends, in {.now} seconds; `-Float::INFINITY` for one
#     that was over before it began
class Cooldown < Data.define(:deadline)
  # Validates the value object on construction.
  #
  # @raise [RuntimeError] if `deadline` is not a {Numeric} — a {Time} is the likely
  #   mistake, and it is the wrong clock, not merely the wrong type
  def initialize(hash)
    super
    raise "deadline must be seconds on the uptime clock but was #{deadline.inspect}" unless deadline.is_a?(Numeric)
  end

  # A cooldown that has always been over — the starting value, and what {#extended_by}
  # measures the first extension against.
  ELAPSED = new(-Float::INFINITY).freeze

  class << self
    # The clock every cooldown is measured on, as a callable returning seconds of uptime.
    # Writable for one reason: Timecop moves the wall clock and cannot move this one, so a
    # spec needing a cooldown to lapse has nowhere else to reach. Production never assigns
    # it, and `Uptime.travel` (`spec/spec_helper.rb`) is the only thing that should — it
    # restores the default in an `ensure`.
    #
    # @return [#call] returns {Float} seconds
    attr_accessor :clock
  end

  # Seconds that only ever advance, at the rate of real time, from an arbitrary origin.
  # Unaffected by anything that moves the wall clock, and (on Linux) it does not tick while
  # the host is suspended.
  self.clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

  # @return [Float] the current reading of {.clock}, in seconds of uptime
  def self.now = clock.call

  # @param seconds [Numeric] how long from now the cooldown runs
  # @return [Cooldown] a cooldown ending `seconds` from now
  def self.of(seconds) = new(now + seconds)

  # @return [Boolean] `true` while the deadline is still ahead
  def active? = Cooldown.now < deadline

  # @return [Float] seconds left, `0.0` once elapsed — never negative, so it is safe to
  #   print without checking {#active?} first
  def remaining = [deadline - Cooldown.now, 0.0].max

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
