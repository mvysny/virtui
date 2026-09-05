# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::AppLayout do
    before do
      Screen.fake
      Helpers.setup_dummy_logger
    end
    after { Screen.close }

    let(:cache) { Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new) }
    let(:layout) do
      l = UI::AppLayout.new(cache, Virt::Ballooning.new(cache))
      Screen.instance.content = l
      l.rect = Rect.new(0, 0, 100, 40)
      l
    end

    it 'smokes' do
      layout
    end

    it 'advertises the 1/2/3 focus keys in the pane chips' do
      assert_equal ' [1]-VMs ', layout.vms.chip.to_s
      assert_equal ' [2]-System ', layout.system.chip.to_s
      assert_equal ' [3]-Log ', layout.log.chip.to_s
    end

    context('handle_key') do
      it 'focuses the pane bound to the pressed digit' do
        assert layout.handle_key('2')
        assert layout.system.active?
        refute layout.vms.active?

        assert layout.handle_key('3')
        assert layout.log.active?
        refute layout.system.active?
      end

      it 'declines a key it has no pane for' do
        refute layout.handle_key('z')
      end
    end

    it 'rect= tiles VMs on top, system │ log along the bottom, status on the last row' do
      layout.rect = Rect.new(0, 0, 100, 40)
      # The status line takes the last row, leaving 39; system width =
      # (100/2).clamp(0,60) = 50; then the 1-cell separator column; system
      # height = 13; VMs take the rest.
      assert_equal [0, 0, 100, 26], rect_of(layout.vms)
      assert_equal [0, 26, 50, 13], rect_of(layout.system)
      assert_equal [51, 26, 49, 13], rect_of(layout.log)
      assert_equal [0, 39, 100, 1], rect_of(layout.status)
    end

    it 'refresh_status advertises quit plus the focused pane\'s own hint, and no chip' do
      layout.rect = Rect.new(0, 0, 100, 40)
      layout.vms.focus
      layout.refresh_status
      text = layout.status.text.to_s.gsub(/\e\[[0-9;]*m/, '')
      assert_includes text, 'quit'
      assert_includes text, 'Power', text
      # The chip lives in the pane header only (DECISIONS.md D_labeled_focus_cues).
      refute_includes text, '[1]-VMs', text
    end

    it 'refresh_status falls back to quit alone for a pane that advertises no keys' do
      layout.rect = Rect.new(0, 0, 100, 40)
      layout.log.focus
      layout.refresh_status
      assert_equal 'q quit', layout.status.text.to_s.gsub(/\e\[[0-9;]*m/, '')
    end

    it 'rect= clamps the system pane width to 60 on a wide screen' do
      layout.rect = Rect.new(0, 0, 200, 40)
      assert_equal 60, layout.system.rect.width
      assert_equal 139, layout.log.rect.width # remainder after the clamped system column + separator
    end

    # The background a pane actually painted, read off the buffer rather than from the
    # component: `Component#effective_bg_color` is protected, and the painted cell is the
    # claim worth asserting anyway.
    # @param pane [Tuile::Component]
    # @return [Tuile::Color, nil] the bg of the pane's bottom-left cell
    def painted_bg(pane)
      Screen.instance.repaint
      Screen.instance.buffer.cell(pane.rect.left, pane.rect.top + pane.rect.height - 1).style.bg
    end

    it 'tints the secondary panes, leaving the VM pane on the terminal default' do
      assert_equal UI::Theme::DARK[:pane_bg], painted_bg(layout.system)
      assert_equal UI::Theme::DARK[:pane_bg], painted_bg(layout.log)
      assert_nil painted_bg(layout.vms)
    end

    it 'derives the pane tint from a reported terminal background, and tracks a change' do
      layout # build on the floor theme first
      mocha = Color.hex('#1e1e2e')
      Screen.instance.background_color = mocha
      derived = UI::Theme.derived(mocha).dark
      assert_equal derived[:pane_bg], Screen.instance.theme[:pane_bg]
      assert_equal derived[:pane_bg], painted_bg(layout.system) # the Ref re-resolves
      assert_equal derived[:frame], Screen.instance.theme[:frame]
    end

    it 'update_data refreshes the panes without raising' do
      layout.update_data
      refute_empty layout.vms.list.items
    end

    def rect_of(component)
      r = component.rect
      [r.left, r.top, r.width, r.height]
    end
  end
end
