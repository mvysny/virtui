# frozen_string_literal: true

require_relative 'spec_helper'

describe UI::Formatter do
  let(:f) { UI::Formatter.new }
  let(:red) { Tuile::Color::RED }
  let(:frame) { Tuile::Color.hex('#333333') }

  describe '#progress_bar2' do
    it 'raises when max_value is negative' do
      assert_raises(RuntimeError) { f.progress_bar2(10, 0, -1, red, frame) }
    end

    it 'returns empty bar when max_value is zero' do
      assert_empty f.progress_bar2(10, 0, 0, red, frame)
    end

    it 'returns empty bar when width is zero' do
      assert_empty f.progress_bar2(0, 5, 10, red, frame)
    end

    it 'renders all dashes when value is zero' do
      bar = f.progress_bar2(8, 0, 100, red, frame)
      assert_equal '--------', bar.to_s
      assert_equal([frame], bar.spans.map { it.style.fg })
    end

    it 'renders all filled chars when value equals max_value' do
      bar = f.progress_bar2(8, 100, 100, red, frame)
      assert_equal '########', bar.to_s
      assert_equal([red], bar.spans.map { it.style.fg })
    end

    it 'renders correct split at 50%' do
      bar = f.progress_bar2(10, 50, 100, red, frame)
      assert_equal '#####-----', bar.to_s
      assert_equal([red, frame], bar.spans.map { it.style.fg })
    end

    it 'clamps value above max_value to max' do
      assert_equal '######', f.progress_bar2(6, 200, 100, red, frame).to_s
    end

    it 'clamps negative value to zero' do
      assert_equal '------', f.progress_bar2(6, -5, 100, red, frame).to_s
    end

    it 'uses the custom char parameter' do
      assert_equal '==--', f.progress_bar2(4, 2, 4, Tuile::Color::GREEN, frame, '=').to_s
    end

    it 'applies the color parameter to the filled portion' do
      bar = f.progress_bar2(4, 4, 4, Tuile::Color.hex('#ff0000'), frame)
      assert_equal Tuile::Color.rgb(255, 0, 0), bar.spans[0].style.fg
    end

    it 'output length equals width' do
      assert_equal 13, f.progress_bar2(13, 7, 20, Tuile::Color::BLUE, frame).display_width
    end
  end
end
