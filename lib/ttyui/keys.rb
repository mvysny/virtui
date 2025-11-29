# frozen_string_literal: true

module Keys
  DOWN_ARROW = "\e[B"
  UP_ARROW = "\e[A"
  DOWN_ARROWS = [DOWN_ARROW, 'j'].freeze
  UP_ARROWS = [UP_ARROW, 'k'].freeze
end
