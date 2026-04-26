# frozen_string_literal: true

class Component
  # A layout doesn't paint anything by itself:
  # its job is to position child components.
  #
  # All children must completely cover the contents of a layout:
  # that way, the layout itself doesn't have to draw and no clipping
  # algorithm is necessary.
  class Layout < Component
    def initialize
      super
      # [Array<Component>]
      @children = []
    end

    def children = @children.to_a

    # Adds a child component to this layout.
    # @param child [Component | Array<Component>]
    def add(child)
      if child.is_a? Enumerable
        child.each { add(it) }
      else
        raise 'Not a component' unless child.is_a? Component
        raise if !child.nil? && !child.parent.nil?

        @children << child
        child.parent = self
      end
    end

    def remove(child)
      raise 'Not a component' unless child.is_a? Component
      raise "Child's parent #{child.parent} is not this one #{self}" if child.parent != self

      child.parent = nil
      @children.delete(child)
      invalidate if @children.empty?
      on_child_removed(child)
    end

    def content_size
      return Size.new(0, 0) if @children.empty?

      right  = @children.map { |c| c.rect.left + c.rect.width  }.max
      bottom = @children.map { |c| c.rect.top  + c.rect.height }.max
      Size.new(right - rect.left, bottom - rect.top)
    end

    def repaint
      clear_background if @children.empty?
    end

    # Dispatches the event to the child under the mouse cursor.
    # @param event [MouseEvent]
    def handle_mouse(event)
      super
      @children.each do |child|
        child.handle_mouse(event) if child.rect.contains?(event.x, event.y)
      end
    end

    # Called when a character is pressed on the keyboard.
    # @param key [String] a key.
    # @return [Boolean] true if the key was handled, false if not.
    def handle_key(key)
      return true if super(key)

      sc = @children.find(&:active?)
      return false if sc.nil?

      sc.handle_key(key)
    end

    def can_activate? = true

    def on_focus
      super
      # Let the content component receive focus, so that it can immediately
      # start responding to key presses.
      first_activatable = @children.find(&:can_activate?)
      screen.focused = first_activatable unless first_activatable.nil?
    end

    # Absolute layout. Extend this class, register any children,
    # and override {:rect=} to reposition the children.
    class Absolute < Layout
    end
  end

  # A mixin interface for a component with one child tops. The component
  # must provide a reader for `content` and override {:content=}.
  # The component must also provide protected `layout(content)` which repositions content component.
  module HasContent
    def can_activate? = true

    # @param key [String] a key.
    # @return [Boolean] true if the key was handled, false if not.
    def handle_key(key)
      content.nil? || !content.active? ? false : content.handle_key(key)
    end

    # @param event [MouseEvent]
    def handle_mouse(event)
      content.handle_mouse(event) if !content.nil? && content.rect.contains?(event.x, event.y)
    end

    def children = content.nil? ? [] : [content]

    # Sets the new content of this component. Updates `@content` itself; including
    # classes may still override to add behaviour (e.g. a special-cased Array
    # input) but should call `super` to perform the swap.
    # @param content [Component | nil] the component to set or clear.
    def content=(content)
      raise unless content.nil? || content.is_a?(Component)
      raise if !content.nil? && !content.parent.nil?
      return if self.content == content

      old = self.content
      old&.parent = nil
      @content = content
      unless content.nil?
        content.parent = self
        content.invalidate
        layout(content)
      end
      on_child_removed(old) unless old.nil?
    end

    def rect=(rect)
      super
      layout(content) unless content.nil?
    end

    def on_focus
      super
      # Let the content component receive focus, so that it can immediately
      # start responding to key presses.
      screen.focused = content if !content.nil? && content.can_activate?
    end
  end
end
