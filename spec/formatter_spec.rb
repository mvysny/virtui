# frozen_string_literal: true

require_relative 'spec_helper'
require 'formatter'

describe Formatter do
  let(:f) do
    Rainbow.enabled = true # force-enable for CI
    Formatter.new
  end

  describe '#progress_bar2' do
    it 'raises when max_value is negative' do
      assert_raises(RuntimeError) { f.progress_bar2(10, 0, -1, :red) }
    end

    it 'returns empty string when max_value is zero' do
      assert_equal '', f.progress_bar2(10, 0, 0, :red)
    end

    it 'returns empty string when width is zero' do
      assert_equal '', f.progress_bar2(0, 5, 10, :red)
    end

    it 'renders all dashes when value is zero' do
      assert_equal "\e[31m\e[0m\e[38;5;59m--------\e[0m", f.progress_bar2(8, 0, 100, :red)
    end

    it 'renders all filled chars when value equals max_value' do
      assert_equal "\e[31m########\e[0m\e[38;5;59m\e[0m", f.progress_bar2(8, 100, 100, :red)
    end

    it 'renders correct split at 50%' do
      assert_equal "\e[31m#####\e[0m\e[38;5;59m-----\e[0m", f.progress_bar2(10, 50, 100, :red)
    end

    it 'clamps value above max_value to max' do
      assert_equal "\e[31m######\e[0m\e[38;5;59m\e[0m", f.progress_bar2(6, 200, 100, :red)
    end

    it 'clamps negative value to zero' do
      assert_equal "\e[31m\e[0m\e[38;5;59m------\e[0m", f.progress_bar2(6, -5, 100, :red)
    end

    it 'uses the custom char parameter' do
      assert_equal "\e[32m==\e[0m\e[38;5;59m--\e[0m", f.progress_bar2(4, 2, 4, :green, '=')
    end

    it 'applies the color parameter to the filled portion' do
      assert_equal "\e[38;5;196m####\e[0m\e[38;5;59m\e[0m", f.progress_bar2(4, 4, 4, '#ff0000')
    end

    it 'output length equals width' do
      assert_equal "\e[34m####\e[0m\e[38;5;59m---------\e[0m", f.progress_bar2(13, 7, 20, :blue)
    end
  end
end
