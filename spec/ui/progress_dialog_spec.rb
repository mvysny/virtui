# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::ProgressDialog do
    before do
      Screen.fake
      Screen.instance.content = Component::Label.new
    end
    after { Screen.close }

    # @return [Array<String>] the dialog's painted rows
    def painted(dialog)
      Screen.instance.repaint
      Screen.instance.buffer.region_text(dialog.absolute_rect)
    end

    it 'paints the caption over the bar, with the cancel key in the footer' do
      assert_equal ['┌Please wait───────────────────────────┐',
                    "│ Reading web01's definition…          │",
                    '│ █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │',
                    '└ESC to cancel─────────────────────────┘'],
                   painted(UI::ProgressDialog.new("Reading web01's definition").open)
    end

    it 'animates the bar on its own' do
      dialog = UI::ProgressDialog.new('Reading').open
      first = painted(dialog)[2]
      Screen.instance.event_queue.tick_once
      refute_equal first, painted(dialog)[2]
    end

    it 'widens to a long caption, up to the screen' do
      dialog = UI::ProgressDialog.new('x' * 60).open
      assert_equal Size.new(65, 4), dialog.declared_size_in(Size.new(160, 50))
      assert_equal Size.new(50, 4), dialog.declared_size_in(Size.new(50, 50))
    end

    it 'fits a screen smaller than its minimum' do
      dialog = UI::ProgressDialog.new('Reading').open
      assert_equal Size.new(30, 3), dialog.declared_size_in(Size.new(30, 3))
    end

    it 'closes on ESC but not on a stray click outside it' do
      dialog = UI::ProgressDialog.new('Reading').open
      Screen.instance.click(0, 0)
      assert dialog.open?
      Screen.instance.key(Keys::ESC)
      refute dialog.open?
    end

    it 'opened not cancelable, swallows ESC and q and says it cannot be canceled' do
      dialog = UI::ProgressDialog.new('Resizing vda', cancelable: false).open
      Screen.instance.key(Keys::ESC)
      Screen.instance.key('q')
      assert dialog.open?
      assert_equal '└cannot be canceled────────────────────┘', painted(dialog).last
    end
  end
end
