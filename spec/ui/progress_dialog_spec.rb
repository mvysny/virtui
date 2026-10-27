# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::ProgressDialog do
    before do
      Screen.fake
      Screen.instance.content = Component::Label.new
    end
    after { Screen.close }

    # @return [Array<String>] the popup's painted rows
    def painted(popup)
      Screen.instance.repaint
      Screen.instance.buffer.region_text(popup.absolute_rect)
    end

    it 'paints the caption over the bar, with the cancel key in the footer' do
      assert_equal ['┌Please wait───────────────────────────┐',
                    "│ Reading web01's definition…          │",
                    '│ █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │',
                    '└ESC to cancel─────────────────────────┘'],
                   painted(UI::ProgressDialog.new("Reading web01's definition").open)
    end

    it 'animates the bar on its own' do
      popup = UI::ProgressDialog.new('Reading').open
      first = painted(popup)[2]
      Screen.instance.event_queue.tick_once
      refute_equal first, painted(popup)[2]
    end

    it 'widens to a long caption, up to the screen' do
      popup = UI::ProgressDialog.new('x' * 60).open
      assert_equal Size.new(65, 4), popup.declared_size_in(Size.new(160, 50))
      assert_equal Size.new(50, 4), popup.declared_size_in(Size.new(50, 50))
    end

    it 'fits a screen smaller than its minimum' do
      popup = UI::ProgressDialog.new('Reading').open
      assert_equal Size.new(30, 3), popup.declared_size_in(Size.new(30, 3))
    end

    it 'closes on ESC but not on a stray click outside it' do
      popup = UI::ProgressDialog.new('Reading').open
      Screen.instance.click(0, 0)
      assert popup.open?
      Screen.instance.key(Keys::ESC)
      refute popup.open?
    end

    it 'opened not cancelable, swallows ESC and q and says it cannot be canceled' do
      popup = UI::ProgressDialog.new('Resizing vda', cancelable: false).open
      Screen.instance.key(Keys::ESC)
      Screen.instance.key('q')
      assert popup.open?
      assert_equal '└cannot be canceled────────────────────┘', painted(popup).last
    end
  end
end
