# frozen_string_literal: true

require 'rainbow'
require_relative 'keys'

class PickerWindow < Window
  # @param caption [String] the window caption
  # @param options [Hash{String => String}] maps keyboard key to the option caption. No Rainbow formatting must be used.
  # @param block called with the option key once one is selected by the user. Not called if the window is closed via ESC or q
  def initialize(caption, options, &block)
    raise 'no options' if options.empty?

    super(caption)
    @options = options
    @block = block
    self.content = options.map { |k, v| "#{k} #{Rainbow(v).cadetblue}" }
    self.cursor = Cursor.new
    width = options.values.map(&:length).max + 6
    height = options.length.clamp(...10)
    self.rect = Rect.new(-1, -1, width, height)
  end

  def handle_key(key)
    super
    if [Keys::ESC, 'q'].include?(key)
      close
    elsif !@options[key].nil?
      @block.call(key)
      close
    end
  end
end
