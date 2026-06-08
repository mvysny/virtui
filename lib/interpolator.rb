# frozen_string_literal: true

# Time-varying value providers used to animate UI quantities smoothly between updates.
#
# Every class in this module exposes a `value` method returning the current value for
# "now"; the result may change from call to call as wall-clock time advances.
# {Interpolator::Const} holds a fixed value, {Interpolator::Linear} ramps linearly
# between two values over a time window.
module Interpolator
end
