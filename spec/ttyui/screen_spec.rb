# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/screen'
require 'ttyui/popup_window'

describe Screen do
  before { Screen.fake }
  after { Screen.close }
  let(:screen) { Screen.instance }

  it 'provides singleton instance' do
    assert_equal screen, Screen.instance
  end

  context 'focused=' do
    before { screen.content = Component::Layout::Absolute.new }

    def add_window
      w = Window.new
      screen.content.add(w)
      w
    end

    it 'raises when given a non-component' do
      assert_raises(RuntimeError) { screen.focused = 'not a component' }
    end

    it 'raises when component is not in the content tree' do
      screen.focused = nil
      w = Window.new
      assert_raises(RuntimeError) { screen.focused = w }
    end

    it 'sets focused to the given component' do
      w = add_window
      screen.focused = w
      assert_equal w, screen.focused
    end

    it 'marks focused component as active' do
      w = add_window
      screen.focused = w
      assert w.active?
    end

    it 'deactivates windows not in the focused path' do
      w1 = add_window
      w2 = add_window
      screen.focused = w1
      screen.focused = w2
      assert !w1.active?
      assert w2.active?
    end

    it 'with nil clears active on all components' do
      w = add_window
      screen.focused = w
      screen.focused = nil
      assert !w.active?
    end

    it 'with nil and no content does not raise' do
      screen2 = Screen.fake
      assert_nil screen2.content
      screen2.focused = nil
    end

    it 'marks all ancestor layouts active when focusing a nested window' do
      nested_layout = Component::Layout::Absolute.new
      screen.content.add(nested_layout)
      w = Window.new
      nested_layout.add(w)
      screen.focused = w
      assert w.active?
      assert nested_layout.active?
    end

    it 'deactivates ancestor layouts when focus moves to a different branch' do
      layout1 = Component::Layout::Absolute.new
      layout2 = Component::Layout::Absolute.new
      screen.content.add(layout1)
      screen.content.add(layout2)
      w1 = Window.new
      w2 = Window.new
      layout1.add(w1)
      layout2.add(w2)
      screen.focused = w1
      screen.focused = w2
      assert !w1.active?
      assert !layout1.active?
      assert w2.active?
      assert layout2.active?
    end

    it 'propagates handle_key through nested layouts to focused window' do
      nested_layout = Component::Layout::Absolute.new
      screen.content.add(nested_layout)
      w = Window.new
      nested_layout.add(w)
      screen.focused = w
      handled = false
      w.define_singleton_method(:handle_key) { |_key| handled = true }
      screen.content.handle_key('x')
      assert handled
    end
  end

  context 'active_window' do
    it 'is nil when no windows' do
      assert_nil screen.active_window
    end
    it 'returns the active window' do
      w = Window.new
      screen.content = Component::Layout::Absolute.new
      screen.content.add(w)
      w.active = true
      assert_equal w, screen.active_window
    end
  end

  context 'popups' do
    it 'adds popup' do
      w = PopupWindow.new
      screen.add_popup w
      assert screen.has_popup? w
    end
    it 'close removes popup' do
      w = PopupWindow.new
      screen.add_popup w
      screen.remove_popup w
      assert !screen.has_popup?(w)
    end

    context 'event routing' do
      let(:popup) do
        w = PopupWindow.new('test')
        w.content = ['hello']
        screen.add_popup(w)
        w
      end

      before do
        screen.content = Component::Layout::Absolute.new
        screen.content.add(Window.new)
      end

      def content_window = screen.content.children.first

      it 'routes keyboard events to popup, not content' do
        popup_received = false
        popup.define_singleton_method(:handle_key) { |_key| popup_received = true; true }
        content_received = false
        content_window.define_singleton_method(:handle_key) { |_key| content_received = true; false }

        screen.send(:handle_key, 'x')

        assert popup_received
        assert !content_received
      end

      it 'routes mouse clicks inside popup to popup' do
        popup_received = false
        popup.define_singleton_method(:handle_mouse) { |_event| popup_received = true }
        content_received = false
        content_window.define_singleton_method(:handle_mouse) { |_event| content_received = true }

        # popup rect: left=75, top=23, width=9, height=3 (centered on 160x50)
        # MouseEvent coords are 1-based; (76,24) maps to (75,23) which is inside
        screen.send(:handle_mouse, MouseEvent.new(:left, 76, 24))

        assert popup_received
        assert !content_received
      end

      it 'does not route mouse clicks outside popup to content' do
        content_received = false
        content_window.define_singleton_method(:handle_mouse) { |_event| content_received = true }

        # click at (1,1) maps to (0,0), outside the popup
        screen.send(:handle_mouse, MouseEvent.new(:left, 1, 1))

        assert !content_received
      end
    end
  end
end
