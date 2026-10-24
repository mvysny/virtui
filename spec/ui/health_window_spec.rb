# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::HealthWindow do
    before { Screen.fake }
    after { Screen.close }

    # @return [Array<String>] the window's text rows, styling stripped
    def text_of(window) = window.instance_variable_get(:@view).text.to_s.lines.map(&:rstrip)

    it 'lists each finding by subject, its fix beneath' do
      finding = Virt::Health::Finding
      health = Virt::Health.new(findings: [
                                  finding.new(:ok, 'balloon', 'virtio, free page reporting', nil),
                                  finding.new(:warning, '/mnt/hc', 'hccrypt (dm-0) blocks discard', 'add `discard`'),
                                  finding.new(:note, 'vda', '2.0G unused after vda1', 'M → Grow root filesystem'),
                                  finding.new(:skipped, 'guest', 'not running', nil)
                                ])
      window = UI::HealthWindow.new('vt-ubuntu', health)
      assert_equal <<~TEXT.lines.map(&:rstrip), text_of(window)
        ✓ balloon  virtio, free page reporting
        ! /mnt/hc  hccrypt (dm-0) blocks discard
                   add `discard`
        · vda      2.0G unused after vda1
                   M → Grow root filesystem
        – guest    not running
      TEXT
      assert_equal 'vt-ubuntu health', window.caption.to_s
    end
  end
end
