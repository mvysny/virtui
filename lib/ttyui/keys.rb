# frozen_string_literal: true

# https://en.wikipedia.org/wiki/ANSI_escape_code
module Keys
  DOWN_ARROW = "\e[B"
  UP_ARROW = "\e[A"
  DOWN_ARROWS = [DOWN_ARROW, 'j'].freeze
  UP_ARROWS = [UP_ARROW, 'k'].freeze
  LEFT_ARROW = "\e[D"
  RIGHT_ARROW = "\e[C"
end
