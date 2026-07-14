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

    it 'assigns the 1/2/3 focus shortcuts to the three windows' do
      assert_equal '1', layout.vms.key_shortcut
      assert_equal '2', layout.system.key_shortcut
      assert_equal '3', layout.log.key_shortcut
    end

    it 'rect= tiles VMs on top, system + log along the bottom' do
      layout.rect = Rect.new(0, 0, 100, 40)
      # system width = (100/2).clamp(0,60) = 50; system height = 13; VMs take the rest.
      assert_equal [0, 0, 100, 27], rect_of(layout.vms)
      assert_equal [0, 27, 50, 13], rect_of(layout.system)
      assert_equal [50, 27, 50, 13], rect_of(layout.log)
    end

    it 'rect= clamps the system window width to 60 on a wide screen' do
      layout.rect = Rect.new(0, 0, 200, 40)
      assert_equal 60, layout.system.rect.width
      assert_equal 140, layout.log.rect.width # remainder after the clamped system column
    end

    it 'update_data refreshes the windows without raising' do
      layout.update_data
      refute_empty layout.vms.content.lines
    end

    def rect_of(component)
      r = component.rect
      [r.left, r.top, r.width, r.height]
    end
  end
end
