# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/scrollbar'

describe VerticalScrollBar do
  context 'height == 1' do
    let(:sb) { VerticalScrollBar.new(1, line_count: 10, top_line: 0) }

    it 'returns | for the only row' do
      assert_equal '|', sb.scrollbar_char(0)
    end

    it 'does not set handle instance variables' do
      assert_nil sb.handle_height
      assert_nil sb.handle_start
      assert_nil sb.handle_end
    end
  end

  context 'height == 2' do
    let(:sb) { VerticalScrollBar.new(2, line_count: 10, top_line: 0) }

    it 'returns ▲ for row 0' do
      assert_equal '▲', sb.scrollbar_char(0)
    end

    it 'returns ▼ for row 1' do
      assert_equal '▼', sb.scrollbar_char(1)
    end

    it 'does not set handle instance variables' do
      assert_nil sb.handle_height
      assert_nil sb.handle_start
      assert_nil sb.handle_end
    end
  end

  context 'height > 2' do
    it 'returns ▲ for row 0' do
      sb = VerticalScrollBar.new(5, line_count: 10, top_line: 0)
      assert_equal '▲', sb.scrollbar_char(0)
    end

    it 'returns ▼ for the last row' do
      sb = VerticalScrollBar.new(5, line_count: 10, top_line: 0)
      assert_equal '▼', sb.scrollbar_char(4)
    end

    context 'content fits (line_count <= height)' do
      let(:sb) { VerticalScrollBar.new(5, line_count: 3, top_line: 0) }

      it 'fills entire track with handle' do
        assert_equal '█', sb.scrollbar_char(1)
        assert_equal '█', sb.scrollbar_char(2)
        assert_equal '█', sb.scrollbar_char(3)
      end

      it 'sets handle_height to full track size' do
        assert_equal 3, sb.handle_height
      end

      it 'sets handle_start to 0' do
        assert_equal 0, sb.handle_start
      end

      it 'sets handle_end to track_size - 1' do
        assert_equal 2, sb.handle_end
      end
    end

    context 'content overflows: 20 lines, height 10, top_line 0' do
      let(:sb) { VerticalScrollBar.new(10, line_count: 20, top_line: 0) }

      it 'computes handle_height' do
        assert_equal 4, sb.handle_height
      end

      it 'sets handle_start to 0 when at top' do
        assert_equal 0, sb.handle_start
      end

      it 'sets handle_end correctly' do
        assert_equal 3, sb.handle_end
      end

      it 'shows handle at top of track' do
        assert_equal '█', sb.scrollbar_char(1)
        assert_equal '█', sb.scrollbar_char(2)
        assert_equal '█', sb.scrollbar_char(3)
        assert_equal '█', sb.scrollbar_char(4)
      end

      it 'shows empty track below handle' do
        assert_equal '░', sb.scrollbar_char(5)
        assert_equal '░', sb.scrollbar_char(8)
      end
    end

    context 'content overflows: 20 lines, height 10, top_line 10' do
      let(:sb) { VerticalScrollBar.new(10, line_count: 20, top_line: 10) }

      it 'sets handle_start at bottom of track' do
        assert_equal 4, sb.handle_start
      end

      it 'sets handle_end at bottom of track' do
        assert_equal 7, sb.handle_end
      end

      it 'shows empty track above handle' do
        assert_equal '░', sb.scrollbar_char(1)
        assert_equal '░', sb.scrollbar_char(4)
      end

      it 'shows handle at bottom of track' do
        assert_equal '█', sb.scrollbar_char(5)
        assert_equal '█', sb.scrollbar_char(8)
      end
    end

    context 'handle_height is at least 1' do
      it 'clamps handle to minimum height of 1 for large content' do
        sb = VerticalScrollBar.new(5, line_count: 1000, top_line: 0)
        assert_equal 1, sb.handle_height
      end
    end

    context 'handle_height does not exceed track size' do
      it 'clamps handle to track_size' do
        sb = VerticalScrollBar.new(4, line_count: 2, top_line: 0)
        assert_equal 2, sb.handle_height  # track_size = 4 - 2 = 2
      end
    end
  end
end
