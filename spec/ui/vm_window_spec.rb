# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

module Tuile
  describe UI::VMWindow do
    before do
      Screen.fake
      @log = Helpers.setup_dummy_logger
    end
    after { Screen.close }
    let(:now) { Time.now }
    let(:cache) { Timecop.freeze(now) { Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new) } }
    let(:ballooning) { Virt::Ballooning.new(cache) }
    let(:window) do
      w = Timecop.freeze(now + 5) do
        cache.update
        UI::VMWindow.new(cache, ballooning)
      end
      Screen.instance.content = w
      w.rect = Rect.new(0, 0, 20, 20)
      w.active = true
      w.content.active = true
      w.show_disk_stat = true
      w
    end

    # The PickerWindow of whatever popup is currently open, or nil.
    def picker = Screen.instance.popups.map(&:content).find { |c| c.is_a?(Component::PickerWindow) }

    # Moves the cursor to `pos`, opens the `menu` popup (p/m), picks `option`, and returns
    # everything logged while doing so.
    def pick(pos, menu, option)
      window.content.cursor.go(pos)
      window.handle_key(menu)
      picker.handle_key(option)
      @log.string
    end

    # Cursor positions of each demo VM (see the 'has the right content' test for the layout).
    # base + Fedora are shut off; Ubuntu + win11 are running.
    def base = 0
    def ubuntu = 4
    def win11 = 8

    it 'has the right content' do
      content = window.content.lines.map(&:to_s)
      assert_equal '⏹ BASE──────────', content[0]
      assert_equal '    vda: 50%   64G   128G |', content[1]
      assert_equal '⏹ Fedora────────', content[2]
      assert_equal '    vda: 50%   64G   128G |', content[3]
      assert_equal '▶ Ubuntu 🎈─────', content[4]
      assert_equal '    CPU:  0%          1 t |   0%          8 t', content[5]
      assert_equal '    RAM: 25%    2G   7.9G |   9%  3.1G    32G', content[6]
      assert_equal '    vda: 50%   64G   128G |', content[7]
      assert_equal '▶ win11 🎈──────', content[8]
      assert_equal '    CPU:  0%          1 t |   0%          8 t', content[9]
      assert_equal '    RAM: 25%    2G   7.9G |   9%  3.1G    32G', content[10]
      assert_equal '    vda: 50%   64G   128G |', content[11]
    end

    it 'show_power_popup opens picker' do
      window.handle_key('p')
      assert(Screen.instance.popups.any? { |it| it.content.is_a?(Component::PickerWindow) })
    end

    it 'show_memory_popup opens picker for running VM' do
      window.content.cursor.go(4) # Ubuntu is running
      window.handle_key('m')
      assert(Screen.instance.popups.any? { |it| it.content.is_a?(Component::PickerWindow) })
    end

    context('cursor movement') do
      it 'moves cursor down correctly' do
        assert_equal 0, window.content.cursor.position
        # first VM is stopped and takes 2 lines
        window.content.handle_key(Keys::DOWN_ARROW)
        assert_equal 2, window.content.cursor.position
        # second VM is running and takes 3 lines
        window.content.handle_key(Keys::DOWN_ARROW)
        assert_equal 4, window.content.cursor.position
        # third VM is running and takes 3 lines
        window.content.handle_key(Keys::DOWN_ARROW)
        assert_equal 8, window.content.cursor.position
        # no more VMs
        window.content.handle_key(Keys::DOWN_ARROW)
        assert_equal 8, window.content.cursor.position
      end
      it 'moves cursor up correctly' do
        window.content.cursor.go(8)
        assert_equal 8, window.content.cursor.position
        window.content.handle_key(Keys::UP_ARROW)
        assert_equal 4, window.content.cursor.position
        window.content.handle_key(Keys::UP_ARROW)
        assert_equal 2, window.content.cursor.position
        window.content.handle_key(Keys::UP_ARROW)
        assert_equal 0, window.content.cursor.position
        window.content.handle_key(Keys::UP_ARROW)
        assert_equal 0, window.content.cursor.position
      end
    end

    context('search') do
      it 'opens a TextField in the footer on /' do
        window.handle_key('/')
        assert_instance_of Component::TextField, window.footer
      end

      it 'ESC closes the search' do
        window.handle_key('/')
        window.footer.handle_key(Keys::ESC)
        assert_nil window.footer
      end

      it 'ENTER closes the search' do
        window.handle_key('/')
        window.footer.handle_key(Keys::ENTER)
        assert_nil window.footer
      end

      it 'shows the cursor on the list while searching' do
        assert window.content.show_cursor_when_inactive
      end

      it 'jumps to the matching VM as the user types' do
        window.handle_key('/')
        window.footer.handle_key('w') # win11
        assert_equal 8, window.content.cursor.position
      end

      it 'is case-insensitive and matches substrings' do
        window.handle_key('/')
        window.footer.text = 'FED' # Fedora
        assert_equal 2, window.content.cursor.position
      end

      it 'down arrow jumps to the next match' do
        window.handle_key('/')
        window.footer.text = 'a' # matches base (0) and Fedora (2)
        assert_equal 0, window.content.cursor.position # lands on base (include_current)
        window.footer.handle_key(Keys::DOWN_ARROW)
        assert_equal 2, window.content.cursor.position # Fedora
      end

      it 'up arrow jumps to the previous match' do
        window.handle_key('/')
        window.footer.text = 'a' # matches base (0) and Fedora (2)
        window.content.cursor.go(2) # Fedora
        window.footer.handle_key(Keys::UP_ARROW)
        assert_equal 0, window.content.cursor.position # base
      end

      it 'down/up wrap around the list' do
        window.handle_key('/')
        window.footer.text = 'a' # matches base (0) and Fedora (2)
        window.content.cursor.go(2) # Fedora — last match
        window.footer.handle_key(Keys::DOWN_ARROW)
        assert_equal 0, window.content.cursor.position # wraps to base
      end

      it 'only lands on cursor-allowed positions (VM header rows)' do
        window.handle_key('/')
        window.footer.text = 'cpu' # appears on stat rows, never on header rows
        # No VM header line contains 'cpu', and stat rows are not allowed positions,
        # so cursor stays put.
        assert_equal 0, window.content.cursor.position
      end
    end

    context('key handling') do
      it "'d' toggles disk stats" do
        assert window.show_disk_stat
        assert window.handle_key('d')
        refute window.show_disk_stat
      end

      it 'returns false for an unhandled key' do
        refute window.handle_key('z')
      end

      it 'ignores VM shortcuts while the search footer is active' do
        window.handle_key('/')
        refute window.handle_key('p')
        assert_nil picker # no power menu opened
      end
    end

    context('keyboard_hint') do
      it 'lists the VM shortcuts when not searching' do
        hint = window.keyboard_hint
        assert hint.include?('Power'), hint
        assert hint.include?('Search'), hint
      end

      it 'shows the search-close hint while searching' do
        window.handle_key('/')
        assert window.keyboard_hint.include?('close search'), window.keyboard_hint
      end
    end

    context('power menu') do
      it 'starts a shut-off VM' do
        assert pick(base, 'p', 's').include?("Starting 'BASE'")
        assert cache.virt.vm('BASE').running?
      end

      it 'refuses to start an already-running VM' do
        assert pick(ubuntu, 'p', 's').include?("'Ubuntu' is already running")
      end

      it 'shuts down a running VM gracefully' do
        assert pick(ubuntu, 'p', 'o').include?("Shutting down 'Ubuntu' gracefully")
      end

      it 'forces off a running VM' do
        assert pick(ubuntu, 'p', 'O').include?("Force off 'Ubuntu'")
        refute cache.virt.vm('Ubuntu').running?
      end

      it 'reboots and resets a running VM' do
        assert pick(ubuntu, 'p', 'r').include?("Asking 'Ubuntu' to reboot")
        assert pick(win11, 'p', 'R').include?("Resetting 'win11' forcefully")
      end

      it 'logs an error when the power action needs a running VM' do
        assert pick(base, 'p', 'o').include?("'BASE' is not running")
        assert pick(base, 'p', 'O').include?("'BASE' is not running")
        assert pick(base, 'p', 'r').include?("'BASE' is not running")
        assert pick(base, 'p', 'R').include?("'BASE' is not running")
      end
    end

    context('memory menu') do
      before { ballooning.update } # register per-VM ballooners so enable/toggle work

      it 'toggles auto-ballooning for a running VM' do
        assert ballooning.enabled?('Ubuntu')
        assert pick(ubuntu, 'm', 'b').include?("Toggling balloning for 'Ubuntu'")
        refute ballooning.enabled?('Ubuntu')
      end

      it 'gives a VM max memory and disables ballooning' do
        log = pick(ubuntu, 'm', 'm')
        assert log.include?('Disabling balooning'), log
        refute ballooning.enabled?('Ubuntu')
        assert_equal 16.GiB, cache.virt.vm('Ubuntu').to_mem_stat.actual # max_actual of demo Ubuntu
      end

      it 'refuses to open the memory menu for a shut-off VM' do
        window.content.cursor.go(base)
        window.handle_key('m')
        assert_nil picker
        assert @log.string.include?("'BASE' is not running")
      end
    end

    context('rendering details') do
      it 'shows the ballooning direction indicator once ballooners exist' do
        ballooning.update
        window.update
        line = window.content.lines.map(&:to_s)[ubuntu]
        assert line.include?("\u{1F388}-"), line # balloon + "steady" (delta 0)
      end

      it "marks a VM whose ballooning the user disabled with 'x'" do
        ballooning.update
        ballooning.enabled('Ubuntu', false)
        window.update
        line = window.content.lines.map(&:to_s)[ubuntu]
        assert line.include?("\u{1F388}x"), line
      end

      it 'maps paused and unknown states to their glyphs' do
        assert window.send(:format_domain_state, :paused).include?("\u{23F8}")
        assert window.send(:format_domain_state, :other).include?('?')
      end

      it 'renders nothing when the window is too narrow' do
        window.rect = Rect.new(0, 0, 10, 20) # column_width = (10-16)/2 < 0 -> early return
        window.update # must not raise
      end
    end
  end
end
