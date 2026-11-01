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
# A new field is an `attr_accessor` with a YARD `@return` type and a default in {#initialize},
# then `rake sig:generate`: Typemap maps every public accessor pair, typed from
# `sig/virtui.rbs`. A missing file or key reads as its default; an unknown key is ignored.
class State
  # @return [Typemap::Mapper]
  MAPPER = Typemap::Mapper.new(types: Typemap::Mapper::RBSTypes.new)

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
  # @raise [RuntimeError] if the file is not a JSON object, or a value is not of its type
  def self.load
    path = self.path
    return new unless File.exist?(path)

    MAPPER.load(State, JSON.load_file(path), unknown: :ignore)
  rescue JSON::ParserError, Typemap::DataError => e
    raise "#{path}: #{e.message}"
  end

  # Writes the state to {.path}, creating its directory. Renamed into place, so a crash
  # mid-write cannot leave a truncated file for the next {.load} to raise on.
  #
  # @return [void]
  def save
    path = State.path
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp"
    File.write(temp, "#{JSON.pretty_generate(MAPPER.dump(self))}\n")
    File.rename(temp, path)
  end
end
