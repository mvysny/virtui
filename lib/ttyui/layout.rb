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
    end

    def repaint
      clear_background if @children.empty?
    end

    # Dispatches the event to the child under the mouse cursor.
    # @param event [MouseEvent]
    def handle_mouse(event)
      super
      @children.each do |child|
        child.handle_mouse(event) if child.rect.contains?(event.x - 1, event.y - 1)
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

    # Absolute layout. Extend this class, register any children,
    # and override {:rect=} to reposition the children.
    class Absolute < Layout
    end
  end

  # A mixin interface for a component with one child tops. The component
  # must provide a reader for `content` and override {:content=}.
  module HasContent
    def can_activate? = true

    # @param key [String] a key.
    # @return [Boolean] true if the key was handled, false if not.
    def handle_key(key)
      content.nil? || !content.active? ? false : content.handle_key(key)
    end

    # @param event [MouseEvent]
    def handle_mouse(event)
      content.handle_mouse(event) if !content.nil? && content.rect.contains?(event.x - 1, event.y - 1)
    end

    def children = content.nil? ? [] : [content]

    # Sets the new content of this component.
    #
    # Note for implementors: override this, call super and then store the new content to `@content`.
    # @param content [Component | nil] the component to set or clear.
    def content=(content)
      raise unless content.nil? || content.is_a?(Component)
      raise if !content.nil? && !content.parent.nil?
      return if self.content == content

      self.content&.parent = nil
      return if content.nil?

      content.parent = self
      content.invalidate
    end
  end
end
