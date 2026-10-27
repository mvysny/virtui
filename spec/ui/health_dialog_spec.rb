# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::HealthDialog do
    before { Screen.fake }
    after { Screen.close }

    let(:finding) { Virt::Health::Finding }
    let(:virt) { Virt::VMEmulator.demo }

    # @param window [UI::HealthDialog]
    # @param width [Integer]
    # @param height [Integer]
    # @return [Array<String>] the painted rows, the border and bar included
    def painted(window, width, height)
      window.open unless window.open?
      Testing.place(window, Rect.new(0, 0, width, height))
      Testing.paint(window).text.map(&:rstrip)
    end

    it 'lists each finding by subject, its fix beneath' do
      health = Virt::Health.new(findings: [
                                  finding.new(:ok, 'balloon', 'virtio, free page reporting', nil),
                                  finding.new(:warning, '/mnt/hc', 'hccrypt (dm-0) blocks discard', 'add `discard`'),
                                  finding.new(:skipped, 'guest', 'not running', nil)
                                ])
      window = UI::HealthDialog.new(virt, 'vt-ubuntu', health)
      assert_equal ['┌vt-ubuntu health────────────────────────┐',
                    '│ ✓ balloon  virtio, free page reporting ░',
                    '│ ! /mnt/hc  hccrypt (dm-0) blocks       ░',
                    '│            discard                     ░',
                    '│            add `discard`               ░',
                    '│ – guest    not running                 ░',
                    '└q/ESC to close──────────────────────────┘'], painted(window, 42, 7)
    end

    it 'wraps a long finding under its own text, and scrolls what does not fit' do
      health = Virt::Health.new(findings: [
                                  finding.new(:note, 'vda', 'unused space after the last partition', 'grow it'),
                                  finding.new(:ok, 'agent', 'connected', nil)
                                ])
      window = UI::HealthDialog.new(virt, 'vt-ubuntu', health)
      assert_equal ['┌vt-ubuntu health──────────┐',
                    '│ · vda    unused space    █',
                    '│          after the last  █',
                    '│          partition       ░',
                    '└q/ESC to close────────────┘'], painted(window, 28, 5)
      assert window.handle_key?(Keys::DOWN_ARROW)
      assert_includes Testing.paint(window).text[3], 'grow it'
    end

    it 'shows a Fix button under a finding it can fix, and none under the others' do
      health = Virt::Health.new(findings: [
                                  finding.new(:note, 'vda', '28G unused after vda1', 'M → Grow root filesystem',
                                              :grow_root),
                                  finding.new(:warning, 'sda', 'the host drops its discards', 'virt-xml …')
                                ])
      window = UI::HealthDialog.new(virt, 'Ubuntu', health)
      rows = painted(window, 50, 8)
      assert_equal '│        [ Fix: grow root filesystem… ]          ░', rows[3]
      assert_equal 1, Testing.find(Component::Button, in: window).size
    end

    it "runs the grow-root flow from the finding's Fix button, closing the window" do
      health = Virt::Health.new(findings: [finding.new(:note, 'vda', '28G unused after vda1', 'M → Grow root',
                                                       :grow_root)])
      UI::HealthDialog.new(virt, 'Ubuntu', health).open
      Testing.click(Testing.get(Component::Button))
      confirm = wait_for('the confirmation') { popup_window(Component::ConfirmDialog) }
      assert_equal "Grow the root filesystem of 'Ubuntu'?", confirm.caption.to_s
      assert_nil popup_window(UI::HealthDialog)
    end

    it 'turns on free page reporting from its Fix button, once confirmed' do
      health = Virt::Health.new(findings: [finding.new(:note, 'balloon', 'no free page reporting', 'virt-xml …',
                                                       :free_page_reporting)])
      UI::HealthDialog.new(virt, 'BASE', health).open
      Testing.click(Testing.get(Component::Button))
      confirm = popup_window(Component::ConfirmDialog)
      assert_includes confirm.message, "virt-xml 'BASE' --edit --memballoon freePageReporting=on"
      Screen.instance.key(Keys::ENTER) # the focused Turn on button
      done = wait_for('the result') { popup_window(Component::ConfirmDialog) { _1 != confirm } }
      assert_equal "Free page reporting is on for 'BASE'", done.caption.to_s
      assert virt.vm('BASE').free_page_reporting
      assert_nil popup_window(UI::HealthDialog)
    end

    it 'says to install virt-xml when it is missing, on the button and when pressed' do
      virt.define_singleton_method(:virt_xml_available?) { false }
      health = Virt::Health.new(findings: [finding.new(:note, 'balloon', 'no free page reporting', 'virt-xml …',
                                                       :free_page_reporting)])
      UI::HealthDialog.new(virt, 'BASE', health).open
      button = Testing.get(Component::Button)
      assert_includes button.caption.to_s, 'please install virt-xml for this to work'
      Testing.click(button)
      assert_includes popup_window(Component::ConfirmDialog).message, 'sudo apt install virt-install'
      refute virt.vm('BASE').free_page_reporting
    end

    # @param klass [Class]
    # @yield [window] an extra filter
    # @return [Component, nil] the topmost open popup that is a `klass`
    def popup_window(klass, &filter)
      Testing.loop
      Screen.instance.overlays.reverse.find { _1.is_a?(klass) && (filter.nil? || filter.call(_1)) }
    end

    # Runs the event loop until the block answers, for a result a {UI::BackgroundTask} hands
    # back from its worker.
    # @param what [String] for the failure message
    # @return [Object] the block's answer
    def wait_for(what)
      deadline = Time.now + 5
      loop do
        Thread.pass
        Testing.loop
        result = yield
        return result if result

        flunk "#{what} never opened" if Time.now > deadline
      end
    end
  end
end
