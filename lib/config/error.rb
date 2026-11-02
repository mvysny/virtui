# frozen_string_literal: true

class Config
  # A config file that cannot be used, its message prefixed with the file's path:
  #
  #     ~/.config/virtui/config.toml: ballooning.raise_at_percent: expected Integer, got "70"; remove the quotes
  class Error < StandardError
  end
end
