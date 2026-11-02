# frozen_string_literal: true

# The user's settings, read once at startup from the first `virtui/config.toml` on the XDG
# config path ({.path}). Every key is optional; a missing file is the defaults:
#
#     # ~/.config/virtui/config.toml
#     [ballooning]
#     raise_at_percent = 70
#
#     config = Config.load
#     config.ballooning.raise_at_percent   # => 70
#     config.ballooning.shrink_at_percent  # => 55, the default
#
# A key is a member of {Config} or of a nested data class, typed by its YARD `@return` through
# `sig/virtui.rbs`, its default in `initialize`; Typemap maps the file onto them. A wrong type,
# a value out of its limits or an unknown key raises {Config::Error} naming the file and the key.
#
# @!attribute [r] ballooning
#   @return [Config::Ballooning] the `[ballooning]` table
class Config < Data.define(:ballooning)
  # @return [Typemap::Mapper]
  MAPPER = Typemap::Mapper.new(types: Typemap::Mapper::RBSTypes.new)

  # @param ballooning [Config::Ballooning]
  def initialize(ballooning: Ballooning.new) = super

  # The first `virtui/config.toml` that exists under `$XDG_CONFIG_HOME` (default `~/.config`),
  # then under each `$XDG_CONFIG_DIRS` entry (default `/etc/xdg`). Only the first is read, never
  # merged. A relative entry is skipped: the XDG Base Directory spec calls it invalid.
  #
  # @param env [Hash{String => String}] the environment to read
  # @return [String, nil] the file's absolute path; `nil` when there is none
  def self.path(env = ENV)
    home = env['XDG_CONFIG_HOME'].to_s
    home = File.join(env.fetch('HOME'), '.config') unless home.start_with?('/')
    dirs = env['XDG_CONFIG_DIRS'].to_s.split(':')
    dirs = ['/etc/xdg'] if dirs.empty?
    [home, *dirs.select { |dir| dir.start_with?('/') }]
      .map { |dir| File.join(dir, 'virtui', 'config.toml') }
      .find { |file| File.exist?(file) }
  end

  # Logs which file it read, at info.
  #
  # @param env [Hash{String => String}] the environment {.path} reads
  # @return [Config] the settings from {.path}; the defaults where it or a key is missing
  # @raise [Config::Error] if the file is not valid TOML, or a value or key does not fit
  def self.load(env = ENV)
    path = self.path(env)
    unless path
      $log.info('No config file; using the defaults')
      return new
    end

    $log.info("Reading config from #{path}")
    MAPPER.load(Config, Tomlrb.load_file(path), source: :toml)
  rescue Tomlrb::ParseError, Typemap::DataError => e
    raise Error, "#{path}: #{e.message}"
  end
end
