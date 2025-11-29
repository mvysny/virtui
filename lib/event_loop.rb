# frozen_string_literal: true

require 'io/console'

# Runs an event loop. Terminates when 'q' is pressed.
# Yields any pressed character to given block. Examples of characters:
# - `\e[B` for down arrow
# - `\e[A` for up arrow
def event_loop
  $stdin.echo = false
  $stdin.raw do
    loop do
      char = $stdin.getch
      break if char == 'q'

      char << $stdin.read_nonblock(3) if char == "\e"
      yield char
    end
  end
ensure
  $stdin.echo = true
end
