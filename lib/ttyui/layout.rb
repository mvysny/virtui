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
      # {Hash{String => Component}} global keyboard shortcuts.
      # When pressed, will focus given component
      @shortcuts = {}
    end

    def children = @children.to_a

    # Adds a child component to this layout.
    # @param child [Component | Array<Component>]
    def add(child)
      if child.is_a? Enumerable
        child.each { add(it) }
      else
        raise 'Not a component' unless child.is_a? Component

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
      @children.each do |child|
        child.handle_mouse(event) if child.rect.contains?(event.x - 1, event.y - 1)
      end
    end

    def get_shortcut_component(key)
      sc = @shortcuts[key]
      return sc unless sc.nil?

      @children.each do |child|
        sc = child.get_shortcut_component(key) if child.respond_to?(:get_shortcut_component)
        return sc unless sc.nil?
      end
      nil
    end

    # Called when a character is pressed on the keyboard.
    # @param key [String] a key.
    # @return [Boolean] true if the key was handled, false if not.
    def handle_key(key)
      sc = get_shortcut_component(key)
      if !sc.nil?
        screen.focused = sc
        true
      else
        sc = @children.find(&:active?)
        return false if sc.nil?

        sc.handle_key(key)
      end
    end

    def can_activate = true

    # Registers a global keyboard shortcut which focuses/activates
    # given component.
    # @param shortcut [String] the key shortcut.
    # @param component [Component] the component to focus.
    def add_shortcut(shortcut, component)
      raise unless component.is_a? Component

      @shortcuts[shortcut] = component
    end

    # Absolute layout. Extend this class, register any children,
    # and override {:rect=} to reposition the children.
    class Absolute < Layout
    end
  end
end
