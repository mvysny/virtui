# frozen_string_literal: true

# What virtui remembers between runs — which of the System and log panes are shown — as JSON
# in {.path}. Load once, then change a field and save:
#
#     state = State.load
#     state.log_pane_visible = false
#     state.save
#     # ~/.local/state/virtui/state.json:
#     #   { "system_pane_visible": true, "log_pane_visible": false }
#
# A missing file or key reads as the pane shown; an unknown key is ignored.
class State
  # @return [Boolean] whether the System pane is shown
  attr_accessor :system_pane_visible
  # @return [Boolean] whether the log pane is shown
  attr_accessor :log_pane_visible

  # Every pane shown, as on a first run; nothing is read.
  def initialize
    @system_pane_visible = true
    @log_pane_visible = true
  end

  # The state file under `$XDG_STATE_HOME`, falling back to `~/.local/state` when the variable
  # is unset, empty or relative — the XDG Base Directory spec calls a relative one invalid.
  #
  # @param env [Hash{String => String}] the environment to read
  # @return [String] the state file's absolute path
  def self.path(env = ENV)
    base = env['XDG_STATE_HOME'].to_s
    base = File.join(env.fetch('HOME'), '.local', 'state') unless base.start_with?('/')
    File.join(base, 'virtui', 'state.json')
  end

  # @return [State] the state from {.path}, the defaults where the file or a key is missing
  # @raise [RuntimeError] if the file is not a JSON object, or a value is not a Boolean
  def self.load
    path = self.path
    state = new
    return state unless File.exist?(path)

    json = begin
      JSON.load_file(path, symbolize_names: true)
    rescue JSON::ParserError => e
      raise "#{path}: #{e.message}"
    end
    raise "#{path}: expected a JSON object but was #{json.inspect}" unless json.is_a?(Hash)

    boolean = lambda do |key, default|
      value = json.fetch(key, default)
      raise "#{path}: #{key} must be true or false but was #{value.inspect}" unless [true, false].include?(value)

      value
    end
    state.system_pane_visible = boolean.call(:system_pane_visible, state.system_pane_visible)
    state.log_pane_visible = boolean.call(:log_pane_visible, state.log_pane_visible)
    state
  end

  # Writes the state to {.path}, creating its directory. Renamed into place, so a crash
  # mid-write cannot leave a truncated file for the next {.load} to raise on.
  #
  # @return [void]
  def save
    path = State.path
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp"
    File.write(temp, "#{JSON.pretty_generate(system_pane_visible:, log_pane_visible:)}\n")
    File.rename(temp, path)
  end
end
