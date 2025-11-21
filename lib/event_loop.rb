require 'io/console'

# Runs an event loop. Terminates when 'q' is pressed.
# Yields any pressed character to given block. Examples of characters:
# - `\e[B` for down arrow
# - `\e[A` for up arrow
def event_loop
  STDIN.echo = false
  STDIN.raw do
    loop do
      char = STDIN.getch
      break if char == 'q'

      char << STDIN.read_nonblock(3) if char == "\e"
      yield char
    end
  end
ensure
  STDIN.echo = true
end
