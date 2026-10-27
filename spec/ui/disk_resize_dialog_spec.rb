# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::DiskResizeDialog do
    before do
      Screen.fake
      Screen.instance.content = Component::Label.new
      Helpers.setup_dummy_logger
    end
    after { Screen.close }

    let(:volume) do
      Virt::Volume.new(path: '/var/lib/libvirt/images/vt-ubuntu.qcow2', pool: 'default', capacity: 14.GiB,
                       allocation: 579.MiB, pool_available: 89.GiB)
    end

    # @param text [String] typed into the focused field, one key at a time
    def type(text) = text.each_char { Screen.instance.key(_1) }

    # @return [Array<String>] the window's painted rows
    def painted(popup)
      Screen.instance.repaint
      Screen.instance.buffer.region_text(popup.absolute_rect)
    end

    # Runs the event loop until the block answers something truthy.
    def wait_for(what)
      deadline = Time.now + 5
      until (found = yield)
        flunk "#{what} never appeared" if Time.now > deadline
        Thread.pass
        Testing.loop
      end
      found
    end

    def popup_of(klass) = Screen.instance.overlays.find { _1.is_a?(klass) }

    context 'parse_size' do
      def parse(text, current = 14.GiB) = UI::DiskResizeDialog.parse_size(text, current)

      it 'grows by a +size, or to a plain size' do
        assert_equal 24.GiB, parse('+10G')
        assert_equal 20.GiB, parse('20G')
        assert_equal 1536.GiB, parse('1.5T')
        assert_equal 14.GiB + 512.MiB, parse('+512 MiB')
        assert_equal 20.GiB, parse(' 20gib ')
      end

      it 'rounds down to whole MiB' do
        assert_equal 20.GiB + 1.MiB, parse('20481.7M')
      end

      it 'grows only' do
        error = assert_raises(ArgumentError) { parse('14G') }
        assert_equal 'grows only: 14G is its size now', error.message
        assert_raises(ArgumentError) { parse('+100K') }
      end

      it 'refuses what is not a size, a bare number included' do
        %w[20 abc 20GB +-5G 10X].push('').each { |text| assert_raises(ArgumentError, text) { parse(text) } }
      end
    end

    it 'shows the image and says what the typed size comes to' do
      popup = UI::DiskResizeDialog.new('vt-ubuntu', 'vda', volume) { flunk 'resized' }.open
      type('+10G')
      assert_equal ["┌Resize vt-ubuntu's vda────────────────────────────┐",
                    '│Image     /var/lib/libvirt/images/vt-ubuntu.qcow2 │',
                    '│Size      14G, 579M of it on the host             │',
                    '│Pool      default, 89G free                       │',
                    '│                                                  │',
                    '│New size  +10G                                    │',
                    '│          → 24G                                   │',
                    '└Enter to resize · ESC to cancel───────────────────┘'],
                   painted(popup)
    end

    it 'warns when the growth is more than the pool holds, and says why a size will not do' do
      popup = UI::DiskResizeDialog.new('vt-ubuntu', 'vda', volume) { flunk 'resized' }.open
      type('+100G')
      assert_includes painted(popup)[6], "→ 114G — more than the pool's 89G free"
      Screen.instance.key(Keys::BACKSPACE) until popup.field.text.empty?
      type('10G')
      assert_includes painted(popup)[6], 'grows only: 14G is its size now'
    end

    it 'hands the size on Enter and closes; refuses Enter on a bad size; ESC closes' do
      got = nil
      popup = UI::DiskResizeDialog.new('vt-ubuntu', 'vda', volume) { got = _1 }.open
      type('10G')
      Screen.instance.key(Keys::ENTER)
      assert popup.open?
      Screen.instance.key(Keys::BACKSPACE) until popup.field.text.empty?
      type('+1G')
      Screen.instance.key(Keys::ENTER)
      refute popup.open?
      assert_equal 15.GiB, got

      popup = UI::DiskResizeDialog.new('vt-ubuntu', 'vda', volume) { flunk 'resized' }.open
      Screen.instance.key(Keys::ESC)
      refute popup.open?
    end

    it 'start resizes a stopped VM end to end, then says the guest is still to do' do
      virt = Virt::VMEmulator.demo
      UI::DiskResizeDialog.start(virt, 'Fedora')
      wait_for('the resize dialog') { popup_of(UI::DiskResizeDialog) }
      type('+10G')
      Screen.instance.key(Keys::ENTER)
      alert = wait_for('the done alert') { popup_of(Component::ConfirmDialog) }
      assert_equal "Fedora's vda is now 138G", alert.caption.to_s
      assert_equal 138.GiB, virt.vm('Fedora').disk_capacity
    end

    it 'start shows what libvirt refused, and resizes nothing' do
      virt = Virt::VMEmulator.demo
      UI::DiskResizeDialog.start(virt, 'Ubuntu') # running: QEMU holds the image's lock
      wait_for('the resize dialog') { popup_of(UI::DiskResizeDialog) }
      type('+10G')
      Screen.instance.key(Keys::ENTER)
      alert = wait_for('the failure alert') { popup_of(Component::ConfirmDialog) }
      assert_equal "Resizing Ubuntu's vda to 138G failed", alert.caption.to_s
      assert_includes alert.message, 'Failed to get "write" lock'
      assert_equal 128.GiB, virt.vm('Ubuntu').disk_capacity
    end
  end
end
