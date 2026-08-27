# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::CpuFlagsWindow do
    before { Screen.fake }
    after { Screen.close }

    # A window narrow enough that every description has to wrap, painted onto the
    # fake screen so the assertions read the actual glyphs.
    def window_for(*flags)
      w = UI::CpuFlagsWindow.new(flags.to_set)
      Screen.instance.content = w
      w.rect = Rect.new(0, 0, 40, 30)
      Screen.instance.repaint
      w
    end

    # The painted rows inside the window's frame, glued back into one line — word
    # wrapping breaks at spaces, so squeezing the row boundaries back to single
    # spaces reconstructs the prose a description was rendered from.
    def painted_text
      buffer = Screen.instance.buffer
      (0...30).map { |y| buffer.row_text(y)[1, 38].to_s.rstrip }.join(' ').gsub(/\s+/, ' ')
    end

    # @return [String] the glossary description of `name`, whitespace-normalized
    def description_of(name)
      UI::CpuFlag::ALL.find { |it| it.name == name }.description.gsub(/\s+/, ' ')
    end

    it 'word-wraps a description instead of ellipsizing it' do
      window_for('svm')
      assert painted_text.include?(description_of('svm')), painted_text
      refute painted_text.include?('…'), painted_text
    end

    it 'explains only the flags this host has' do
      window_for('svm', 'npt')
      text = painted_text
      assert text.include?(description_of('npt')), text
      refute text.include?(description_of('vmx')), text
      refute text.include?(description_of('software')), text
    end

    it 'explains software emulation when neither vmx nor svm is present' do
      window_for
      assert painted_text.include?(description_of('software')), painted_text
    end

    it 're-renders on flags=' do
      w = window_for('svm')
      w.flags = %w[vmx].to_set
      Screen.instance.repaint
      assert painted_text.include?(description_of('vmx')), painted_text
    end

    it 'opens as a popup' do
      Screen.instance.content = Component::Label.new
      popup = UI::CpuFlagsWindow.open(%w[svm npt].to_set)
      assert_equal [popup], Screen.instance.popups
      assert_equal UI::CpuFlagsWindow::SIZE, popup.size
    end
  end
end
