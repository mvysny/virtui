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

    it 'advertises the 1/2/3 focus keys in the window captions' do
      assert_equal '[1]-VMs', layout.vms.caption.to_s
      assert_equal '[2]-System', layout.system.caption.to_s
      assert_equal '[3]-Log', layout.log.caption.to_s
    end

    context('handle_key') do
      it 'focuses the window bound to the pressed digit' do
        assert layout.handle_key('2')
        assert layout.system.active?
        refute layout.vms.active?

        assert layout.handle_key('3')
        assert layout.log.active?
        refute layout.system.active?
      end

      it 'declines a key it has no window for' do
        refute layout.handle_key('z')
      end
    end

    it 'rect= tiles VMs on top, system + log along the bottom, status on the last row' do
      layout.rect = Rect.new(0, 0, 100, 40)
      # The status line takes the last row, leaving 39; system width =
      # (100/2).clamp(0,60) = 50; system height = 13; VMs take the rest.
      assert_equal [0, 0, 100, 26], rect_of(layout.vms)
      assert_equal [0, 26, 50, 13], rect_of(layout.system)
      assert_equal [50, 26, 50, 13], rect_of(layout.log)
      assert_equal [0, 39, 100, 1], rect_of(layout.status)
    end

    it 'refresh_status advertises quit plus the focused window\'s own hint' do
      layout.rect = Rect.new(0, 0, 100, 40)
      layout.vms.focus
      layout.refresh_status
      text = layout.status.text.to_s.gsub(/\e\[[0-9;]*m/, '')
      assert_includes text, 'quit'
      assert_includes text, 'Power', text
    end

    it 'rect= clamps the system window width to 60 on a wide screen' do
      layout.rect = Rect.new(0, 0, 200, 40)
      assert_equal 60, layout.system.rect.width
      assert_equal 140, layout.log.rect.width # remainder after the clamped system column
    end

    it 'update_data refreshes the windows without raising' do
      layout.update_data
      refute_empty layout.vms.content.items
    end

    def rect_of(component)
      r = component.rect
      [r.left, r.top, r.width, r.height]
    end
  end
end
