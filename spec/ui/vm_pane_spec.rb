# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

module Tuile
  describe UI::VMPane do
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
        UI::VMPane.new(cache, ballooning)
      end
      mount_at(w, Rect.new(0, 0, 20, 20))
      w.active = true
      w.list.active = true
      w.show_disk_stat = true
      w
    end

    # Runs the event loop until the block answers something truthy, and returns that.
    def wait_for(what)
      deadline = Time.now + 5
      until (found = yield)
        flunk "#{what} never appeared" if Time.now > deadline
        Thread.pass
        Testing.loop
      end
      found
    end

    # @return [Array<Tuile::Component>] what the open popups hold
    def popup_contents = Screen.instance.popups.map(&:content)

    # The PickerWindow of whatever popup is currently open, or nil.
    def picker = Screen.instance.popups.map(&:content).find { |c| c.is_a?(Component::PickerWindow) }

    # Moves the cursor to `pos`, opens the `menu` popup (p/m), picks `option`, and returns
    # everything logged while doing so.
    def pick(pos, menu, option)
      window.list.cursor.go(pos)
      window.handle_key?(menu)
      picker.handle_key?(option)
      @log.string
    end

    # Moves the cursor to `pos`, opens the `menu` popup (p/M), and returns its disabled options.
    # @return [Hash{String => String}] option key → why it is disabled
    def disabled_options(pos, menu)
      window.list.cursor.go(pos)
      window.handle_key?(menu)
      picker.content.items.select(&:disabled?).to_h { [_1.key, _1.disabled_reason] }
    end

    # @return [Array<String>] every rendered guest swap-out line, top to bottom
    def swap_lines = list_rows(window.list).grep(/SWAP/)

    # One VM's swap row as text, styling stripped, at a width that leaves 42-column cells.
    #
    # @param entry [Virt::Cache::VMCache] the VM's cache entry
    # @return [String] the rendered row
    def swap_line(entry) = window.send(:swap_row, entry).render.call(95).gsub(/\e\[[\d;:]*m/, '')

    # Cursor positions of each demo VM (see the 'has the right content' test for the layout).
    # base + Fedora are shut off; Ubuntu + win11 are running.
    def base = 0
    def ubuntu = 4
    # 9, not 8: every running VM carries a SWAP line, so Ubuntu is 5 lines.
    def win11 = 9

    # The first timer tick is 2 s away; the cache already holds a poll, so the pane must
    # show it the moment it is built.
    it 'lists the VMs as soon as it is built, before any tick' do
      pane = UI::VMPane.new(cache, ballooning)
      mount_at(pane, Rect.new(0, 0, 20, 20))
      assert_equal '⏹ ?  BASE─────────', list_rows(pane.list)[0]
    end

    it 'moves the header captions with the pane width' do
      header = -> { window.instance_variable_get(:@header).text.to_s }
      mount_at(window, Rect.new(0, 0, 80, 20))
      assert_equal 15, header.call.index('Guest usage')
      mount_at(window, Rect.new(0, 0, 120, 20))
      assert_equal 25, header.call.index('Guest usage')
      assert_equal 85, header.call.index('Host usage')
    end

    it 'has the right content' do
      content = list_rows(window.list)
      # BASE declares no OS, so it gets the dim '?' where Fedora gets a penguin
      assert_equal '⏹ ?  BASE─────────', content[0]
      # a stopped guest has no filesystems to report, and the emulated host tracks no disks
      assert_equal '    vda:    │    ', content[1]
      assert_equal '⏹ 🐧 Fedora───────', content[2]
      assert_equal '    vda:    │    ', content[3]
      assert_equal '▶ 🐧 Ubuntu 🎈────', content[4]
      assert_equal '    CPU:  0%          1 t │   0%          8 t', content[5]
      assert_equal '    RAM: 25%    2G   7.9G │   9%  3.1G    32G', content[6]
      # Ubuntu swaps: 15M written in the 5s since boot, so a level to show and a live rate
      assert_equal '   SWAP:  0%   15M     4G │       3M/s  ↕  15M', content[7]
      # the guest's own filesystems: / and /boot/efi
      assert_equal '    vda:  9%  9.4G    95G │    ', content[8]
      assert_equal '▶ 🪟 win11 🎈─────', content[9]
      assert_equal '    CPU:  0%          1 t │   0%          8 t', content[10]
      assert_equal '    RAM: 25%    2G   7.9G │   9%  3.1G    32G', content[11]
      # win11 is at rest and reports no level at all, so its guest cell is the '-' placeholder
      assert_equal '   SWAP:  -               │        0/s  ↕    0', content[12]
      assert_equal '    vda: 24%   31G   127G │    ', content[13]
    end

    it 're-lays its rows out to a new width without an update' do
      window
      mount_at(window, Rect.new(0, 0, 40, 20)) # 38 text columns: less the gutters; the rows fit, so no scrollbar
      assert_equal 38, StyledString.parse(list_rows(window.list)[base]).display_width
    end

    context('address inset') do
      def overview(width, address)
        e = Virt::Cache::VMCache.diff(nil, cache.data('Ubuntu'), nil, Virt::GuestOS::UNKNOWN, address)
        window.send(:overview_row, e).render.call(width).gsub(/\e\[[\d;:]*m/, '')
      end

      it 'sits at the right end of the rule, the line keeping its width' do
        assert_equal '▶ ?  Ubuntu 🎈─────────── 192.168.122.84 ─', overview(42, '192.168.122.84')
        assert_equal '▶ ?  Ubuntu 🎈────────────────────────────', overview(42, nil)
      end

      it 'is dropped whole rather than clipped when the rule has no room' do
        assert_equal '▶ ?  Ubuntu 🎈────', overview(18, '192.168.122.84')
      end
    end

    context('balloon words') do
      def header(width, address = '192.168.122.84')
        window.send(:header, width, 'Ubuntu 🎈↑', address, words: 'raised to 2.6G: 70% used', tone: :hint)
              .gsub(/\e\[[\d;:]*m/, '')
      end

      it 'sit between the caption and the address' do
        assert_equal 'Ubuntu 🎈↑ raised to 2.6G: 70% used ─────── 192.168.122.84 ─', header(60)
        assert_equal 'Ubuntu 🎈↑ raised to 2.6G: 70% used ───────', header(43, nil)
      end

      it 'are cut before the address is, and kept ─── clear of it' do
        assert_equal 'Ubuntu 🎈↑ raised to 2.6… ─── 192.168.122.84 ─', header(46)
      end

      it 'are dropped when not even a letter and the ellipsis fit beside the address' do
        assert_equal 'Ubuntu 🎈↑────── 192.168.122.84 ─', header(33)
      end

      it 'get the whole rule once the address no longer fits' do
        assert_equal 'Ubuntu 🎈↑ raised to… ───', header(25)
      end
    end

    it 'puts what the ballooning is doing in the header, colored by severity' do
      ballooning.update
      window.update
      list = window.list
      # the demo Ubuntu at 25% wants a lower, and just booted: held by the boot back-off
      line = list.renderer.call(list.items[ubuntu], 60).to_s
      assert_includes line, Screen.instance.theme.warn('‖')
      assert_includes line, Screen.instance.theme.warn('holding 20s: settling')
    end

    it 'show_power_popup opens picker' do
      window.handle_key?('p')
      assert(Screen.instance.popups.any? { |it| it.content.is_a?(Component::PickerWindow) })
    end

    it 'show_memory_popup opens picker for running VM' do
      window.list.cursor.go(4) # Ubuntu is running
      window.handle_key?('m')
      assert(Screen.instance.popups.any? { |it| it.content.is_a?(Component::PickerWindow) })
    end

    context('cursor movement') do
      it 'moves cursor down correctly' do
        assert_equal 0, window.list.cursor.position
        # first VM is stopped and takes 2 lines
        window.list.handle_key?(Keys::DOWN_ARROW)
        assert_equal 2, window.list.cursor.position
        # second VM is running and takes 3 lines
        window.list.handle_key?(Keys::DOWN_ARROW)
        assert_equal 4, window.list.cursor.position
        # third VM is running, so it takes 5 lines (header, CPU, RAM, SWAP, disk)
        window.list.handle_key?(Keys::DOWN_ARROW)
        assert_equal 9, window.list.cursor.position
        # no more VMs
        window.list.handle_key?(Keys::DOWN_ARROW)
        assert_equal 9, window.list.cursor.position
      end
      it 'moves cursor up correctly' do
        window.list.cursor.go(9)
        assert_equal 9, window.list.cursor.position
        window.list.handle_key?(Keys::UP_ARROW)
        assert_equal 4, window.list.cursor.position
        window.list.handle_key?(Keys::UP_ARROW)
        assert_equal 2, window.list.cursor.position
        window.list.handle_key?(Keys::UP_ARROW)
        assert_equal 0, window.list.cursor.position
        window.list.handle_key?(Keys::UP_ARROW)
        assert_equal 0, window.list.cursor.position
      end
    end

    context('search') do
      it 'opens a TextField row on /' do
        window.handle_key?('/')
        assert_instance_of Component::TextField, window.search
      end

      it 'ESC closes the search' do
        window.handle_key?('/')
        window.search.handle_key?(Keys::ESC)
        assert_nil window.search
      end

      it 'ENTER closes the search' do
        window.handle_key?('/')
        window.search.handle_key?(Keys::ENTER)
        assert_nil window.search
      end

      # The invariant outside a search: cursor visible ⟺ the VM pane owns the keyboard.
      it 'shows the inactive-list cursor only while searching' do
        refute window.list.show_cursor_when_inactive
        window.handle_key?('/')
        assert window.list.show_cursor_when_inactive
        window.search.handle_key?(Keys::ESC)
        refute window.list.show_cursor_when_inactive
      end

      it 'jumps to the matching VM as the user types' do
        window.handle_key?('/')
        window.search.handle_key?('w') # win11
        assert_equal 9, window.list.cursor.position
      end

      it 'is case-insensitive and matches substrings' do
        window.handle_key?('/')
        window.search.value = 'FED' # Fedora
        assert_equal 2, window.list.cursor.position
      end

      it 'down arrow jumps to the next match' do
        window.handle_key?('/')
        window.search.value = 'a' # matches base (0) and Fedora (2)
        assert_equal 0, window.list.cursor.position # lands on base (include_current)
        window.search.handle_key?(Keys::DOWN_ARROW)
        assert_equal 2, window.list.cursor.position # Fedora
      end

      it 'up arrow jumps to the previous match' do
        window.handle_key?('/')
        window.search.value = 'a' # matches base (0) and Fedora (2)
        window.list.cursor.go(2) # Fedora
        window.search.handle_key?(Keys::UP_ARROW)
        assert_equal 0, window.list.cursor.position # base
      end

      it 'down/up wrap around the list' do
        window.handle_key?('/')
        window.search.value = 'a' # matches base (0) and Fedora (2)
        window.list.cursor.go(2) # Fedora — last match
        window.search.handle_key?(Keys::DOWN_ARROW)
        assert_equal 0, window.list.cursor.position # wraps to base
      end

      it 'only lands on cursor-allowed positions (VM header rows)' do
        window.handle_key?('/')
        window.search.value = 'cpu' # appears on stat rows, never on header rows
        # No VM header line contains 'cpu', and stat rows are not allowed positions,
        # so cursor stays put.
        assert_equal 0, window.list.cursor.position
      end
    end

    context('key handling') do
      it "'d' toggles disk stats" do
        assert window.show_disk_stat
        assert window.handle_key?('d')
        refute window.show_disk_stat
      end

      it "'i' reads the VM's definition in the background and opens the info window" do
        window.list.cursor.go(win11)
        assert window.handle_key?('i')
        info = nil
        deadline = Time.now + 5
        while info.nil?
          flunk 'the info window never opened' if Time.now > deadline
          Thread.pass
          Testing.loop
          info = Screen.instance.popups.map(&:content).find { _1.is_a?(UI::VMInfoWindow) }
        end
        text = info.instance_variable_get(:@view).text.to_s
        assert_includes text, 'UEFI, Secure Boot'
        assert_includes text, "vda  virtio  qcow2  128G\n"
        assert_includes text, 'NTFS  C:\\', "the guest's own view of its disk"
      end

      it "'M' disables resize on a running VM and grow on a stopped one" do
        assert_equal({ 'r' => 'shut the VM down first' }, disabled_options(ubuntu, 'M'))
        Screen.instance.key(Keys::ESC)
        assert_equal({ 'g' => 'start the VM first' }, disabled_options(base, 'M'))
      end

      it "'M' → a disabled item does nothing and keeps the menu open" do
        pick(ubuntu, 'M', 'r')
        assert picker
        refute popup_contents.any?(Component::ConfirmWindow)
      end

      it "'M' → resize on a VM started since the menu opened says to shut it down" do
        window.list.cursor.go(base)
        window.handle_key?('M')
        cache.virt.start('BASE')
        Timecop.freeze(now + 15) { cache.update }
        picker.handle_key?('r')
        alert = popup_contents.find { _1.is_a?(Component::ConfirmWindow) }
        assert_includes alert.message, 'Shut BASE down first'
      end

      it "'M' → resize on a stopped VM opens the resize dialog once its disks are read" do
        pick(base, 'M', 'r')
        wait_for('the resize dialog') { popup_contents.find { _1.is_a?(UI::DiskResizeWindow) } }
      end

      it "'M' → grow on a running VM confirms the commands, grows, and reports the new size" do
        pick(ubuntu, 'M', 'g')
        confirm = wait_for('the confirmation') { popup_contents.find { _1.is_a?(Component::ConfirmWindow) } }
        assert_equal "Grow Ubuntu's root filesystem?", confirm.caption.to_s
        assert_includes confirm.message, 'grows by 28G, into the free space at the end of vda'
        assert_includes confirm.message, 'runs sfdisk, partx, resize2fs as root inside the guest'
        Screen.instance.key(Keys::ENTER) # the focused Grow button
        done = wait_for('the result') { popup_contents.find { _1.is_a?(Component::ConfirmWindow) && _1 != confirm } }
        assert_equal "Ubuntu's / is now 128G", done.caption.to_s
        assert_equal 128.GiB - 107.MiB, cache.virt.vm('Ubuntu').root_size
      end

      it "'M' → health on a running VM lists its findings, the guest's included" do
        pick(win11, 'M', 'h')
        health = wait_for('the health window') { popup_contents.find { _1.is_a?(UI::HealthWindow) } }
        text = health.instance_variable_get(:@view).text.to_s
        assert_includes text, "the host drops this disk's discards"
        assert_includes text, 'virt-xml win11 --edit target=vda --disk discard=unmap'
      end

      it "'M' → health on a stopped VM judges its definition, and skips the guest" do
        pick(base, 'M', 'h')
        health = wait_for('the health window') { popup_contents.find { _1.is_a?(UI::HealthWindow) } }
        assert_includes health.instance_variable_get(:@view).text.to_s, 'not running: start the VM for the guest checks'
      end

      it 'returns false for an unhandled key' do
        refute window.handle_key?('z')
      end

      it 'ignores VM shortcuts while the search row is active' do
        window.handle_key?('/')
        refute window.handle_key?('p')
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
        window.handle_key?('/')
        assert window.keyboard_hint.include?('close search'), window.keyboard_hint
      end
    end

    context('power menu') do
      it 'starts a shut-off VM' do
        assert pick(base, 'p', 's').include?("Starting 'BASE'")
        assert cache.virt.vm('BASE').running?
      end

      it 'disables starting a running VM and the rest on a stopped one' do
        assert_equal({ 's' => 'VM not stopped' }, disabled_options(ubuntu, 'p'))
        Screen.instance.key(Keys::ESC)
        assert_equal(%w[o u O r b R].to_h { [_1, 'VM not running'] }, disabled_options(base, 'p'))
      end

      it 'disables the SysRq items for a guest that would ignore them' do
        assert_equal({ 's' => 'VM not stopped', 'u' => 'not a Linux guest', 'b' => 'not a Linux guest' },
                     disabled_options(win11, 'p'))
        Screen.instance.key(Keys::ESC)
        cache.virt.vm('Ubuntu').sysrq_mask = 16
        cache.virt.vm('Ubuntu').force_off
        Timecop.freeze(now + 15) { cache.update } # the mask is read once per boot
        cache.virt.vm('Ubuntu').start
        Timecop.freeze(now + 17) { cache.update }
        assert_equal "the guest's kernel.sysrq = 16 allows no remount or power-off", disabled_options(ubuntu, 'p')['u']
      end

      it 'powers a running VM off through SysRq' do
        pick(ubuntu, 'p', 'u')
        wait_for('the power-off') { @log.string.include?("'Ubuntu' synced, remounted read-only and powered off") }
        refute cache.virt.vm('Ubuntu').running?
      end

      it 'reboots a running VM through SysRq' do
        pick(ubuntu, 'p', 'b')
        wait_for('the reboot') { @log.string.include?("'Ubuntu' synced, remounted read-only and rebooted") }
      end

      it 'logs an error when the VM stopped since the menu opened, for the SysRq items too' do
        window.list.cursor.go(ubuntu)
        window.handle_key?('p')
        cache.virt.force_off('Ubuntu')
        Timecop.freeze(now + 15) { cache.update }
        picker.handle_key?('u')
        assert_includes @log.string, "'Ubuntu': no SysRq power-off: VM not running"
      end

      it 'refuses to start a VM started since the menu opened' do
        window.list.cursor.go(base)
        window.handle_key?('p')
        cache.virt.start('BASE')
        Timecop.freeze(now + 15) { cache.update }
        picker.handle_key?('s')
        assert_includes @log.string, "'BASE' is already running"
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

      it 'logs an error when the VM stopped since the menu opened' do
        window.list.cursor.go(ubuntu)
        window.handle_key?('p')
        cache.virt.force_off('Ubuntu')
        Timecop.freeze(now + 15) { cache.update }
        picker.handle_key?('o')
        assert_includes @log.string, "'Ubuntu' is not running"
      end
    end

    context('memory menu') do
      before { ballooning.update } # register per-VM ballooners so enable/toggle work

      it 'toggles auto-ballooning for a running VM' do
        assert ballooning.enabled?('Ubuntu')
        assert pick(ubuntu, 'm', 'b').include?("Toggling ballooning for 'Ubuntu'")
        refute ballooning.enabled?('Ubuntu')
      end

      it 'gives a VM max memory and disables ballooning' do
        log = pick(ubuntu, 'm', 'm')
        assert log.include?('Disabling ballooning'), log
        refute ballooning.enabled?('Ubuntu')
        assert_equal 16.GiB, cache.virt.vm('Ubuntu').to_mem_stat.actual # max_actual of demo Ubuntu
      end

      it 'disables both items on a shut-off VM' do
        assert_equal({ 'b' => 'VM not running', 'm' => 'VM not running' }, disabled_options(base, 'm'))
      end

      it 'logs an error when the VM stopped since the menu opened' do
        window.list.cursor.go(ubuntu)
        window.handle_key?('m')
        cache.virt.force_off('Ubuntu')
        Timecop.freeze(now + 15) { cache.update }
        picker.handle_key?('b')
        assert_includes @log.string, "'Ubuntu' is not running"
        assert ballooning.enabled?('Ubuntu')
      end
    end

    context('rendering details') do
      it 'shows what the ballooning is doing once ballooners exist' do
        ballooning.update
        window.update
        line = list_rows(window.list)[ubuntu]
        # the demo Ubuntu at 25% wants a lower, and just booted: held by the boot back-off
        assert line.include?("\u{1F388}\u2016"), line
      end

      it "marks a VM whose ballooning the user disabled with 'x'" do
        ballooning.update
        ballooning.enabled('Ubuntu', false)
        window.update
        line = list_rows(window.list)[ubuntu]
        assert line.include?("\u{1F388}x"), line
      end

      it 'marks each VM with what its definition declares' do
        content = list_rows(window.list)
        assert_includes content[ubuntu], "\u{1F427} Ubuntu" # declared Linux
        assert_includes content[win11], "\u{1FA9F} win11" # declared Windows
        assert_includes content[base], '?  BASE' # declares nothing
      end

      # The whole set, not a sample: a glyph whose emoji presentation needs a variation
      # selector measures 1 (☀️, 🕸️), and one such row shifts its VM name a column left.
      it 'pads every guest-OS marker to the same width, so the name column holds' do
        families = Virt::GuestOS::FAMILIES.keys + [:unknown]
        markers = families.map { |family| window.send(:format_guest_os, Virt::GuestOS.new(family, nil)) }
        assert_equal [UI::VMPane::GUEST_OS_WIDTH],
                     markers.map { |m| StyledString.parse(m).display_width }.uniq
      end

      # The header's column captions: measured in display columns, so an emoji or a styled
      # chip before the caption doesn't push it off its column.
      it 'places a caption at a display column, and drops it when the line is already past' do
        chip = "\e[7m🐧\e[0m" # 2 columns, 1 character, wrapped in SGR
        placed = StyledString.parse(window.send(:place, chip, 5, 'Guest'))
        assert_equal '🐧   Guest', placed.to_s
        assert_equal chip, window.send(:place, chip, 1, 'Guest')
      end

      it 'draws a glyph for every family a definition can declare' do
        assert_equal Virt::GuestOS::FAMILIES.keys.sort, UI::VMPane::GUEST_OS_GLYPHS.keys.sort
      end

      it 'maps paused and unknown states to their glyphs' do
        assert window.send(:format_domain_state, :paused).include?("\u{23F8}")
        assert window.send(:format_domain_state, :other).include?('?')
      end

      it 'keeps the swap line but drops the rate to zero once the guest stops swapping' do
        assert_includes swap_lines[0], '3M/s' # forces the window to be built before the clock moves
        Timecop.freeze(now + 10) do
          cache.virt.vm('Ubuntu').swap_out_rate = 0 # counter plateaus, it does not reset
          cache.update # still reports the 15M genuinely written over the interval just ended
        end
        Timecop.freeze(now + 15) { cache.update } # first interval with a flat counter
        window.update
        # the level and the lifetime traffic keep the scar, only the rate goes quiet
        assert_equal '   SWAP:  0%   30M     4G │        0/s  ↕  30M', swap_lines[0]
      end

      it 'reports a zero rate when a reboot resets the guest counter' do
        assert_includes swap_lines[0], '3M/s'
        Timecop.freeze(now + 10) do
          cache.virt.vm('Ubuntu').force_reboot
          cache.update
        end
        window.update
        assert_includes swap_lines[0], '    0/s'
      end

      it 'draws the guest swap level like the RAM bar above it' do
        entry = cache.cache('Ubuntu').with(guest_swap: ResourceUsage.of(4.GiB, 1.GiB))
        assert_equal '   SWAP: 25%    1G ######-------------------    4G │        ' \
                     '-/s ------------------------ ↕    0', swap_line(entry)
      end

      # Blank would read as an empty swap device; this guest simply cannot be asked.
      it 'marks an unreadable level with a dash, keeping the rate in its own column' do
        entry = cache.cache('Ubuntu').with(guest_swap: nil)
        assert_equal '   SWAP:  -        -------------------------       │        ' \
                     '-/s ------------------------ ↕    0', swap_line(entry)
      end

      # The demo guest never faults anything back, so swap_in is 0 there and the sum needs
      # its own case: the host paid for the traffic in both directions.
      it 'sums the lifetime counters into one traffic figure' do
        entry = cache.cache('Ubuntu')
        entry = entry.with(data: entry.data.with(mem_stat: entry.data.mem_stat.with(swap_in: 5.MiB, swap_out: 10.MiB)))
        assert_includes swap_line(entry), '↕  15M'
      end

      it 'drops the swap line entirely when the guest reports no swap counters' do
        entry = cache.cache('Ubuntu') # the emulator always reports them, so blank them out here
        entry = entry.with(data: entry.data.with(mem_stat: entry.data.mem_stat.with(swap_in: nil, swap_out: nil)))
        assert_nil window.send(:swap_row, entry)
      end

      it 'renders rows narrower than their captions without raising' do
        mount_at(window, Rect.new(0, 0, 10, 20)) # 7 text columns, so column_width clamps to 0
        list_rows(window.list)
      end
    end
  end
end
