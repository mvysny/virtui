# frozen_string_literal: true

require_relative 'spec_helper'

describe Config do
  around do |example|
    Dir.mktmpdir('virtui-config') do |dir|
      @dir = dir
      example.run
    end
  end

  before { @log = Helpers.setup_dummy_logger }

  # @return [Hash{String => String}] an environment whose XDG config dirs are under the temp dir
  def env = { 'HOME' => "#{@dir}/home", 'XDG_CONFIG_HOME' => "#{@dir}/user", 'XDG_CONFIG_DIRS' => "#{@dir}/sys1:#{@dir}/sys2" }

  # @param base [String] the config dir, relative to the temp dir
  # @param contents [String] the file's TOML
  # @return [String] the file's path
  def write_config(base, contents)
    path = File.join(@dir, base, 'virtui', 'config.toml')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  # @param contents [String] the user's config.toml
  # @return [Config::Error]
  def load_error(contents)
    write_config('user', contents)
    assert_raises(Config::Error) { Config.load(env) }
  end

  context('path') do
    it 'is nil when there is no file' do
      assert_nil Config.path(env)
    end

    it 'takes XDG_CONFIG_HOME first, then each XDG_CONFIG_DIRS entry in order' do
      sys2 = write_config('sys2', '')
      assert_equal sys2, Config.path(env)
      sys1 = write_config('sys1', '')
      assert_equal sys1, Config.path(env)
      user = write_config('user', '')
      assert_equal user, Config.path(env)
    end

    it 'falls back to ~/.config when XDG_CONFIG_HOME is unset, empty or relative' do
      path = write_config('home/.config', '')
      assert_equal path, Config.path(env.except('XDG_CONFIG_HOME'))
      assert_equal path, Config.path(env.merge('XDG_CONFIG_HOME' => ''))
      assert_equal path, Config.path(env.merge('XDG_CONFIG_HOME' => 'user'))
    end

    it 'skips a relative XDG_CONFIG_DIRS entry' do
      write_config('sys1', '')
      Dir.chdir(@dir) { assert_nil Config.path(env.merge('XDG_CONFIG_DIRS' => 'sys1')) }
    end
  end

  context('load') do
    it 'gives the defaults when there is no file' do
      config = Config.load(env)
      assert_equal Config.new, config
      assert_equal 65, config.ballooning.raise_at_percent
      assert_equal 55, config.ballooning.shrink_at_percent
      assert_equal 8, config.ballooning.min_actual_gib
      assert_includes @log.string, 'No config file'
    end

    it 'keeps the default of every key the file leaves out' do
      path = write_config('user', "[ballooning]\nraise_at_percent = 70\n")
      config = Config.load(env)
      assert_equal Config::Ballooning.new(raise_at_percent: 70), config.ballooning
      assert_includes @log.string, path
    end

    it 'reads only the first file found' do
      write_config('user', "[ballooning]\nraise_at_percent = 70\n")
      write_config('sys1', "[ballooning]\nmin_actual_gib = 4\n")
      assert_equal Config::Ballooning.new(raise_at_percent: 70), Config.load(env).ballooning
    end

    it 'names the file and the key of a wrong type' do
      e = load_error("[ballooning]\nraise_at_percent = \"70\"\n")
      assert_equal %(#{@dir}/user/virtui/config.toml: ballooning.raise_at_percent: expected Integer, got "70"), e.message
    end

    it 'rejects a value out of its limits' do
      assert_includes load_error("[ballooning]\nraise_at_percent = 170\n").message,
                      'ballooning.raise_at_percent: 170 is not in 1..100'
      assert_includes load_error("[ballooning]\nmin_actual_gib = 0\n").message, 'ballooning.min_actual_gib: 0 is not in 1..'
    end

    it 'rejects an unknown key' do
      assert_includes load_error("[ballooning]\nrasie_at_percent = 70\n").message, 'ballooning.rasie_at_percent: unknown key'
      assert_includes load_error("[balooning]\n").message, 'balooning: unknown key'
    end

    it 'rejects a raise trigger at or below the shrink trigger' do
      assert_includes load_error("[ballooning]\nraise_at_percent = 55\n").message,
                      'ballooning: raise_at_percent (55) must be above shrink_at_percent (55)'
    end

    it 'names the file of a TOML syntax error' do
      e = load_error("[ballooning\n")
      assert_includes e.message, "#{@dir}/user/virtui/config.toml: "
      assert_includes e.message, 'line 1'
    end
  end
end
