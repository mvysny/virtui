# frozen_string_literal: true

require_relative 'keys'
require_relative 'component'

class Component
  # A single-line text input field with hardware-cursor caret.
  #
  # The field does not scroll. Any keystroke that would make {#text} longer than
  # `rect.width - 1` (the last column is reserved for the caret past the last char)
  # is rejected.
  #
  # The caret is a logical index in `0..text.length`. The hardware cursor is
  # positioned by {Screen} after each repaint cycle when this component is
  # active; see {Component#cursor_position}.
  class TextField < Component
    def initialize
      super
      @text = +''
      @caret = 0
    end

    # @return [String] current text contents.
    attr_reader :text

    # @return [Integer] caret index in `0..text.length`.
    attr_reader :caret

    # Sets the text. Truncates to fit if longer than `rect.width - 1`. Caret is
    # clamped to the new text length.
    # @param new_text [String]
    def text=(new_text)
      new_text = new_text.to_s
      new_text = new_text[0, max_text_length] if new_text.length > max_text_length
      return if @text == new_text

      @text = +new_text
      @caret = @caret.clamp(0, @text.length)
      invalidate
    end

    # Sets the caret position. Clamped to `0..text.length`.
    # @param new_caret [Integer]
    def caret=(new_caret)
      new_caret = new_caret.clamp(0, @text.length)
      return if @caret == new_caret

      @caret = new_caret
      invalidate
    end

    def can_activate? = true

    def cursor_position
      return nil unless active? && rect.width.positive?

      Point.new(rect.left + @caret, rect.top)
    end

    def handle_key(key)
      return false unless active?
      return true if super

      case key
      when Keys::LEFT_ARROW then self.caret = @caret - 1
      when Keys::RIGHT_ARROW then self.caret = @caret + 1
      when Keys::HOME then self.caret = 0
      when Keys::END_ then self.caret = @text.length
      when *Keys::BACKSPACES then delete_before_caret
      when Keys::DELETE then delete_at_caret
      else
        return insert(key) if printable?(key)

        return false
      end
      true
    end

    def handle_mouse(event)
      super
      return unless event.button == :left && rect.contains?(event.x - 1, event.y - 1)

      self.caret = (event.x - 1 - rect.left).clamp(0, @text.length)
    end

    def repaint
      clear_background
      return if rect.empty?

      screen.print TTY::Cursor.move_to(rect.left, rect.top), @text
    end

    protected

    def on_width_changed
      super
      return if @text.length <= max_text_length

      @text = @text[0, [max_text_length, 0].max]
      @caret = @caret.clamp(0, @text.length)
    end

    private

    # Maximum number of characters {#text} can hold given current width.
    def max_text_length = (rect.width - 1).clamp(0, nil)

    def insert(char)
      return false if @text.length >= max_text_length

      @text = @text.dup.insert(@caret, char)
      @caret += 1
      invalidate
      true
    end

    def delete_before_caret
      return if @caret.zero?

      @text = @text.dup
      @text.slice!(@caret - 1)
      @caret -= 1
      invalidate
    end

    def delete_at_caret
      return if @caret >= @text.length

      @text = @text.dup
      @text.slice!(@caret)
      invalidate
    end

    def printable?(key)
      key.length == 1 && key.ord >= 0x20 && key.ord < 0x7f
    end
  end
end
