# frozen_string_literal: true

require 'rainbow'
require_relative 'keys'
require_relative 'popup_window'

class PickerWindow < PopupWindow
  # Scrolls the window when more items
  MAX_ITEMS = 10

  # One picker option, has a {String} keyboard `key` and the {String} option caption
  class Option < Data.define(:key, :caption)
  end

  # @param caption [String] the window caption
  # @param options [Array<Array<String, String>>] pair sof keyboard key + option caption. No Rainbow formatting must be used.
  # @param block called with the option key once one is selected by the user. Not called if the window is closed via ESC or q
  def initialize(caption, options, &block)
    raise 'no options' if options.empty?

    super(caption)
    options = options.map { Option.new(it[0], it[1]) }
    @options = options
    @block = block
    self.content = options.map { "#{it.key} #{Rainbow(it.caption).cadetblue}" }
    # Always enable cursor
    self.cursor = Cursor.new
  end

  def handle_key(key)
    return true if super

    if @options.any? { it.key == key }
      select_option(key)
      true
    elsif key == Keys::ENTER
      selected = @options[cursor.position]
      select_option(selected.key)
      true
    else
      false
    end
  end

  # @param caption [String] the window caption
  # @param options [Array<Option>] maps keyboard key to the option caption. No Rainbow formatting must be used.
  # @param block called with the option key once one is selected by the user. Not called if the window is closed via ESC or q
  # @return [PickerWindow]
  def self.open(caption, options, &block)
    picker = PickerWindow.new(caption, options, &block)
    picker.open
    picker
  end

  protected

  def select_option(key)
    @block.call(key)
    close
  end
end
