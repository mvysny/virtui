# frozen_string_literal: true

require_relative 'spec_helper'

describe State do
  let(:path) { File.join(ENV.fetch('XDG_STATE_HOME'), 'virtui', 'state.json') }

  # @param contents [String] the state file's JSON
  # @return [void]
  def write_state(contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  context('path') do
    it 'lives under XDG_STATE_HOME' do
      assert_equal '/x/state/virtui/state.json', State.path('XDG_STATE_HOME' => '/x/state', 'HOME' => '/home/me')
    end

    it 'falls back to ~/.local/state when XDG_STATE_HOME is unset, empty or relative' do
      expected = '/home/me/.local/state/virtui/state.json'
      assert_equal expected, State.path('HOME' => '/home/me')
      assert_equal expected, State.path('XDG_STATE_HOME' => '', 'HOME' => '/home/me')
      assert_equal expected, State.path('XDG_STATE_HOME' => 'state', 'HOME' => '/home/me')
    end

    it 'reads ENV by default' do
      assert_equal path, State.path
    end
  end

  context('load') do
    it 'shows every pane with no file' do
      state = State.load
      assert state.system_pane_visible
      assert state.log_pane_visible
    end

    it 'defaults a missing key and ignores an unknown one' do
      write_state('{ "log_pane_visible": false, "future_key": 3 }')
      state = State.load
      assert state.system_pane_visible
      refute state.log_pane_visible
    end

    it 'raises on broken JSON, naming the file' do
      write_state('{ "log_pane_visible": ')
      e = assert_raises(RuntimeError) { State.load }
      assert_includes e.message, path
    end

    it 'raises on JSON that is not an object' do
      write_state('[true]')
      e = assert_raises(RuntimeError) { State.load }
      assert_includes e.message, 'expected a table'
    end

    it 'raises on a value that is not a Boolean' do
      write_state('{ "log_pane_visible": "no" }')
      e = assert_raises(RuntimeError) { State.load }
      assert_includes e.message, 'log_pane_visible'
    end
  end

  # Every field off its default, so one that save or load forgets fails here.
  it 'save creates the directory and round-trips through load' do
    state = State.load
    state.system_pane_visible = false
    state.log_pane_visible = false
    state.save
    assert_equal "{\n  \"system_pane_visible\": false,\n  \"log_pane_visible\": false\n}\n", File.read(path)
    reloaded = State.load
    refute reloaded.system_pane_visible
    refute reloaded.log_pane_visible
    refute File.exist?("#{path}.tmp")
  end
end
