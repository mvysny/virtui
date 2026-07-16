# frozen_string_literal: true

require_relative '../spec_helper'

describe UI::Formatter do
  let(:f) { UI::Formatter }
  let(:red) { Tuile::Color::RED }
  let(:frame) { Tuile::Color.hex('#333333') }

  describe '#progress_bar' do
    it 'raises when max_value is negative' do
      assert_raises(RuntimeError) { f.progress_bar(10, 0, -1, red, frame) }
    end

    it 'returns empty bar when max_value is zero' do
      assert_empty f.progress_bar(10, 0, 0, red, frame)
    end

    it 'returns empty bar when width is zero' do
      assert_empty f.progress_bar(0, 5, 10, red, frame)
    end

    it 'renders all dashes when value is zero' do
      bar = f.progress_bar(8, 0, 100, red, frame)
      assert_equal '--------', bar.to_s
      assert_equal([frame], bar.spans.map { |it| it.style.fg })
    end

    it 'renders all filled chars when value equals max_value' do
      bar = f.progress_bar(8, 100, 100, red, frame)
      assert_equal '########', bar.to_s
      assert_equal([red], bar.spans.map { |it| it.style.fg })
    end

    it 'renders correct split at 50%' do
      bar = f.progress_bar(10, 50, 100, red, frame)
      assert_equal '#####-----', bar.to_s
      assert_equal([red, frame], bar.spans.map { |it| it.style.fg })
    end

    it 'clamps value above max_value to max' do
      assert_equal '######', f.progress_bar(6, 200, 100, red, frame).to_s
    end

    it 'clamps negative value to zero' do
      assert_equal '------', f.progress_bar(6, -5, 100, red, frame).to_s
    end

    it 'uses the custom char parameter' do
      assert_equal '==--', f.progress_bar(4, 2, 4, Tuile::Color::GREEN, frame, '=').to_s
    end

    it 'applies the color parameter to the filled portion' do
      bar = f.progress_bar(4, 4, 4, Tuile::Color.hex('#ff0000'), frame)
      assert_equal Tuile::Color.rgb(255, 0, 0), bar.spans[0].style.fg
    end

    it 'output length equals width' do
      assert_equal 13, f.progress_bar(13, 7, 20, Tuile::Color::BLUE, frame).display_width
    end
  end

  describe '#labelled_bar' do
    # display_width strips ANSI, so it measures the rendered column count.
    def width_of(str) = Tuile::StyledString.parse(str).display_width

    it 'pads the left caption to label_width and the right caption to 6' do
      bar = f.labelled_bar(30, '50%', '128G', 50, 100, red, frame, label_width: 11)
      assert bar.start_with?('50%'.ljust(11)), bar
      assert bar.end_with?('128G'.rjust(6)), bar
    end

    it 'total rendered width equals the given width' do
      assert_equal 30, width_of(f.labelled_bar(30, '50%', '128G', 50, 100, red, frame, label_width: 11))
    end

    it 'skips left padding when the left caption is empty' do
      bar = f.labelled_bar(20, '', '9G', 3, 10, red, frame, label_width: 11)
      refute bar.start_with?(' '), bar # first char is the filled bar, not padding
    end

    it 'collapses the bar to empty when captions leave no room' do
      bar = f.labelled_bar(10, '50%', '128G', 50, 100, red, frame, label_width: 11)
      assert_equal '50%'.ljust(11) + '128G'.rjust(6), bar # bar width clamped to 0
    end
  end
end
