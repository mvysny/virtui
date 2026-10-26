# frozen_string_literal: true

module UI
  # The VM pane: a scrollable, cursor-selectable list of all VMs, each with guest-vs-host
  # CPU/RAM/disk usage bars and a ballooning-status indicator. Per-VM actions are reachable
  # via key shortcuts: power menu (`p`), launch viewer (`v`), memory menu (`m`), toggle disk
  # stats (`d`), the VM's definition (`i`) and search (`/`).
  #
  # A borderless `Layout::Vertical`, not a `Window` (see design/decisions.md D_panes_are_layouts):
  # a one-row header — the focus chip plus the Guest/Host column captions — over the
  # {Tuile::Component::List}, with the incremental-search {Tuile::Component::TextField}
  # appearing as a third row while open (a row in the pane's own layout, not an overlay:
  # a `Popup` is modal, and a focusable non-modal `Overlay` is
  # forbidden upstream — the row plus one explicit {#close_search} re-focus is strictly
  # simpler).
  #
  # UI-thread-confined.
  class VMPane < Tuile::Component::Layout::Vertical
    include Tuile

    # Separates a row's guest half from its host half. The same vertical bar the pane
    # separator column uses, so the two columns read as framed rather than piped apart.
    COLUMN_SEPARATOR = '│'

    # Width of a split row's caption, colon included — `    CPU:`, `   SWAP:`, `    vda:` —
    # so the guest column starts at the same place on every row.
    ROW_CAPTION_WIDTH = 8

    # Width of the caption cell every row opens its column with, bar rows and the swap row
    # alike — what keeps their figures in one column.
    LABEL_WIDTH = 11

    # One list row: the VM it belongs to, and how to draw it at the list's text width.
    #
    #   Row.new('Ubuntu', ->(width) { '─' * width })
    #
    # The cache is read when the row is built, never inside `render`: the list renders at
    # paint time and again on every width change, and a row must keep showing the sample
    # it was built from.
    #
    # @!attribute [r] vm
    #   @return [String] the VM's name — what the power/memory keys act on
    # @!attribute [r] render
    #   @return [Proc] `(Integer width) -> String`, the row laid out to `width` columns
    Row = Data.define(:vm, :render)

    # The rate that fills the swap-out gauge. A rate has no natural 100%, so this is a chosen
    # alarm scale and not a ratio: it is set high enough that a guest thrashing hard still has
    # bar left to grow into, which costs sensitivity at the bottom — on a ~100-column terminal
    # the gauge's first character lights at ~0.8 MiB/s, so a trickle below that reads as an
    # empty bar and only the warn-colored label reports it. Not self-scaled to each VM's own
    # peak: a per-VM denominator makes the bar mean something different per row and per
    # minute, and comparing VMs down the list is what the column is for. Not a log scale
    # either — it reads as linear to anyone who does not know it isn't.
    SWAP_RATE_FULL_SCALE = 20.MiB

    # Width of the swap row's `↕traffic` tail — the arrow plus a 5-char byte size. Fixed, so
    # every VM's gauge is the same length and the bars stay comparable down the list.
    SWAP_TOTALS_WIDTH = 6

    # The guest-OS marker drawn between a VM's state glyph and its name, keyed by
    # {Virt::GuestOS#family}. Emoji, because the overview line is already read by its glyphs
    # (▶/⏹/🎈/🐢), and a family with no entry here — `:unknown` — falls through to the
    # dim `?` {#format_guest_os} draws instead. It sits *left* of the name because the
    # declaration never changes while virtui runs; the things that do (balloon, arrow, turtle)
    # stay right of the name, where a tick-by-tick change costs nothing.
    #
    # One entry per {Virt::GuestOS::FAMILIES} key, so every declaration osinfo-db can express
    # draws something. Where a project has a mascot the mascot wins (🐧 Tux, 😈 Beastie,
    # 🐡 Puffy, 🚩 NetBSD's flag, 🍎 Apple, 🌞 Sun, 🍃 Haiku's leaf); the rest are the
    # nearest recognisable stand-in, because Unicode has no dragonfly and no gnu. Every glyph
    # here measures {GUEST_OS_WIDTH} — checked against `unicode/display_width`, not assumed:
    # the obvious ☀️ for Solaris and 🕸️ for NetWare measure **1**, being variation sequences,
    # and are why those two rows are 🌞 and 🌐.
    GUEST_OS_GLYPHS = {
      linux: "\u{1F427}", # 🐧 Tux
      # 🪟 is Emoji 13 (2020), the set's one font-coverage risk: a tofu box is usually one
      # cell and shifts the name. Fallback if it bites: a padded "W ".
      windows: "\u{1FA9F}",      # 🪟
      freebsd: "\u{1F608}",      # 😈 Beastie, the BSD daemon
      openbsd: "\u{1F421}",      # 🐡 Puffy the pufferfish
      netbsd: "\u{1F6A9}",       # 🚩 the flag of its logo
      dragonflybsd: "\u{1F409}", # 🐉 no dragonfly in Unicode; the dragon is the near miss
      macos: "\u{1F34E}",        # 🍎
      solaris: "\u{1F31E}",      # 🌞 Sun Microsystems
      illumos: "\u{1F4A1}",      # 💡 *illuminare*, which is where the name comes from
      haiku: "\u{1F343}",        # 🍃 the leaf of its logo
      dos: "\u{1F4BE}",          # 💾
      netware: "\u{1F310}"       # 🌐 Novell's networking-first pitch
    }.freeze

    # Display width every guest-OS marker is padded to. All of {GUEST_OS_GLYPHS} measure 2
    # (tuile sizes rows via `unicode/display_width`), so a narrower marker — or a blank one —
    # would pull that row's VM name a column left and cost the list its name column.
    GUEST_OS_WIDTH = 2

    # The character after 🎈 and the {Theme} reader that colors it and the words after it,
    # keyed by {Virt::BallooningVM::Status#kind}; a kind with no entry draws a plain `-` and
    # no words. The color is the severity: grey for routine, warn for a lower that is held,
    # error for a guest short of memory that virtui cannot give it.
    #
    # In the header, not the focused VM's status bar: a capped guest must be seen at a glance,
    # without the cursor on it. `‖` rather than ⏸ for holding: ⏸ renders emoji-wide in some
    # fonts and shifts the rest of the line, and the screen promises to need no special font.
    BALLOON_GLYPHS = {
      raised: ['↑', :hint],
      lowered: ['↓', :hint],
      at_floor: ['_', :hint],
      holding: ['‖', :warn],     # the guest vetoed a lower
      backing_off: ['‖', :warn], # our own back-off did
      at_max: ['▲', :error]
    }.freeze

    # @param virt_cache [Virt::Cache] the runtime cache to read VM data from and act through
    # @param ballooning [Virt::Ballooning] the ballooning controller toggled from the memory menu
    def initialize(virt_cache, ballooning)
      super()
      @virt_cache = virt_cache
      @ballooning = ballooning
      @show_disk_stat = false
      # TextField, nil: the incremental-search row while open — see {#open_search}.
      @search = nil
      @header = Component::Label.new
      @list = Component::List.new
      @list.renderer = ->(row, width) { row.render.call(width) }
      @list.cursor = Component::List::Cursor.new
      @list.scrollbar_visibility = :auto
      add(@header, Fixed[1])
      add(@list, Expand[1])
      rebuild_header
      update
    end

    # @return [Tuile::Component::List] the VM list — the pane's focus target
    attr_reader :list

    # @return [Tuile::Component::TextField, nil] the incremental-search row while open,
    #   nil otherwise — see {#open_search}
    attr_reader :search

    # @return [Boolean] whether disk stats are shown for shut-off VMs too
    attr_reader :show_disk_stat

    # Focuses the VM list. The pane itself is passive layout; the list is what owns the
    # cursor and the keyboard.
    # @return [void]
    def focus
      @list.focus
    end

    # Toggles showing disk stats for shut-off VMs and re-renders.
    # @param value [Boolean] true to show disk stats for shut-off VMs
    def show_disk_stat=(value)
      @show_disk_stat = !!value
      update
    end

    # Rebuilds every VM's rows (overview + guest/host CPU, RAM and disk bars) from the
    # current cache data, and recomputes the allowed cursor positions. The rows lay
    # themselves out at paint time, so a resize needs no call here.
    #
    # @return [void]
    def update
      theme = screen.theme
      domains = @virt_cache.domains.sort_by(&:upcase) # Array<String>
      cursor_positions = [] # allowed cursor positions
      cpus = @virt_cache.cpu_info.cpus
      host_ram = @virt_cache.host_mem_stat.ram
      rows = []
      domains.each do |domain_name|
        cursor_positions << rows.size
        # {Virt::Cache::VMCache}
        cache = @virt_cache.cache(domain_name)
        # {Virt::DomainData}
        data = cache.data
        rows << overview_row(cache)

        if data.running?
          cpu_usage = cache.guest_cpu_usage.to_i
          host_cpu_usage = (cache.cpu_usage / cpus).to_i
          guest_cpus = data.info.cpus
          rows << split_row(domain_name, "    #{theme.cpu('CPU')}") do |width|
            [progress_bar("#{cpu_usage.to_s.rjust(3)}%", "#{guest_cpus.to_s.rjust(3)} t", width,
                          cpu_usage, 100, theme[:cpu_vm]),
             progress_bar("#{host_cpu_usage.to_s.rjust(3)}%", "#{cpus.to_s.rjust(3)} t", width,
                          host_cpu_usage, 100, theme[:cpu])]
          end

          guest_mem_usage = data.mem_stat.guest_mem
          host_mem_usage = ResourceUsage.of(host_ram.total, data.mem_stat.host_mem.used)
          rows << split_row(domain_name, "    #{theme.ram('RAM')}") do |width|
            [usage_bar(width, guest_mem_usage, theme[:ram_vm]), usage_bar(width, host_mem_usage, theme[:ram])]
          end

          swap = swap_row(cache)
          rows << swap unless swap.nil?
        end
        next unless @show_disk_stat || data.running?

        data.disk_stat.each do |ds| # {Virt::DiskStat}
          host_du = @virt_cache.host_disk_usage(ds)
          rows << split_row(domain_name, "   #{theme.disk_label(ds.name[0..3].rjust(4))}") do |width|
            [guest_disk_bar(width, cache, ds.name), usage_bar(width, host_du, theme[:disk])]
          end
        end
      end
      @list.items = rows
      @list.cursor = if cursor_positions.empty?
                       Component::List::Cursor.new
                     else
                       Component::List::Cursor::Limited.new(cursor_positions, position: @list.cursor.position)
                     end
    end

    # Handles a key press: `/` opens search; `p`/`v`/`m`/`d`/`i`/`M` act on the VM under the
    # cursor (power menu, launch viewer, memory menu, toggle disk stats, info, maintenance).
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key?(key)
      return true if super
      return false if @search&.active?

      if key == '/'
        open_search
        return true
      end

      return false if current_vm.nil?

      if key == 'p' # Power menu
        show_power_popup
        true
      elsif key == 'v' # view
        $log.info "Launching viewer for '#{current_vm}'"
        Run.async('virt-manager', '--connect', 'qemu:///system',
                  '--show-domain-console', current_vm)
        true
      elsif key == 'm' # memory
        show_memory_popup
        true
      elsif key == 'd'
        self.show_disk_stat = !show_disk_stat
        true
      elsif key == 'i'
        show_info_popup
        true
      elsif key == 'M'
        show_maintenance_popup
        true
      else
        false
      end
    end

    # @return [Tuile::StyledString] the pane's focus chip, inverted iff the pane owns the
    #   keyboard. `[1]` mirrors {AppLayout}'s focus-key map.
    def chip
      Formatter.chip('1', 'VMs', focused: active?, theme: screen.theme)
    end

    # @return [String] the footer hint line, listing the available key shortcuts (or the
    #   search-close hint while searching)
    def keyboard_hint
      t = screen.theme
      return "#{t.key('ESC')} #{t.hint('close search')}" if @search

      "#{t.key('p')} #{t.hint('Power')}  #{t.key('v')} #{t.hint('run Viewer')}  " \
        "#{t.key('m')} #{t.hint('Memory')}  #{t.key('d')} #{t.hint('toggle Disk stat')}  " \
        "#{t.key('i')} #{t.hint('Info')}  #{t.key('M')} #{t.hint('Maintenance')}  #{t.key('/')} #{t.hint('Search')}"
    end

    # Rebuilds the header when the pane enters or leaves the focus chain — the chip's
    # inverted/dim state is baked into the header label's text.
    # @param value [Boolean]
    # @return [void]
    def active=(value)
      super
      rebuild_header
    end

    protected

    # Re-centers the column captions on the pane's width; the list re-lays its rows out by
    # itself. Runs after every mark, not only a resize — the rebuild is cheap and
    # `Label#text=` skips an unchanged row.
    # @return [void]
    def relayout
      super
      rebuild_header
    end

    # Re-renders when the theme changes, so colors follow the new palette.
    # @return [void]
    def handle_theme_changed
      super
      rebuild_header
      update
    end

    private

    # @return [String, nil] the VM the row under the cursor belongs to; nil with no cursor
    def current_vm
      position = @list.cursor.position
      @list.items[position]&.vm unless position.nil?
    end

    # Rebuilds the header row: the focus chip, then the Guest/Host column captions.
    #
    # The captions are load-bearing column headers — every VM row renders guest-side |
    # host-side bar pairs and these are the only thing saying which is which — but they are
    # static dim labels, deliberately not flipping with focus: the chip is the pane's one
    # inverted element, and a two-shade caption flip is a relative cue the reader must remember
    # the resting shade to read. Centered at 1/4 and 3/4 of the pane width, over the middle of
    # each bar column.
    #
    # @return [void]
    def rebuild_header
      theme = screen.theme
      line = chip.to_ansi
      fourth = rect.width / 4
      line = place(line, fourth - 5, theme.hint('Guest usage'))
      line = place(line, (3 * fourth) - 5, theme.hint('Host usage'))
      @header.text = line
    end

    # Appends `text` to `line` so it starts at column `at`, space-padded; appends nothing
    # when `line` has already grown past `at` (a too-narrow pane).
    #
    # @param line [String] the ANSI-styled row built so far
    # @param at [Integer] target start column
    # @param text [String] ANSI-styled text to place
    # @return [String] the extended row
    def place(line, at, text)
      styled = StyledString.parse(line)
      return line if styled.display_width > at

      styled.ljust(at).to_ansi + text
    end

    # Opens the incremental-search text field as a bottom row of the pane, wiring its events
    # to move the list cursor to matching VMs. While the field holds focus the list is
    # inactive, so the cursor is kept painted via `show_cursor_when_inactive` — scoped to
    # the search so that outside it *cursor visible ⟺ the VM pane owns the keyboard*.
    # @return [void]
    def open_search
      return if @search

      field = Component::TextField.new
      # ESC closes the row instead of tuile's default of merely dropping focus — which
      # would leave the search field on screen with nothing focusing it back.
      field.escape_clears_focus = false
      field.on_escape << method(:close_search)
      field.on_enter << method(:close_search)
      # The cursor follows every keystroke, not tuile's default of the commit on leave/ENTER;
      # matching a handful of VM names is free, so there is nothing for :lazy to debounce.
      field.value_change_mode = :eager
      field.on_value_change { |e| @list.select_next(e.value, include_current: true) }
      field.on_key_down { @list.select_next(field.text) }
      field.on_key_up { @list.select_prev(field.text) }
      @search = field
      @list.show_cursor_when_inactive = true
      add(field, Fixed[1])
      field.focus
    end

    # Closes the search row, handing focus back to the list (a Layout has no `Window#footer=`
    # focus repair; this explicit re-focus is the whole cost of the row-not-overlay choice).
    # @return [void]
    def close_search
      field = @search
      return if field.nil?

      @search = nil
      @list.show_cursor_when_inactive = false
      @list.focus
      remove(field)
    end

    # Opens {VMInfoWindow} for the selected VM once its definition is read, fresh on every
    # press so the window never shows a definition older than the keypress
    # (design/decisions.md D_background_task). The guest is asked for its disk layout only
    # when the live definition says its agent is connected; one that still cannot answer
    # gets the reason in the window rather than failing the whole read.
    # @return [void]
    def show_info_popup
      vm = current_vm || return
      virt = @virt_cache.virt
      task = BackgroundTask.new("Reading #{vm}'s definition") do
        config = virt.domain_config(vm)
        guest = begin
          virt.guest_storage(vm) if config.agent == :connected
        rescue Virt::GuestAgent::Unavailable => e
          # virsh's own `error: …` line, not the `Command '…' failed` wrapper around it.
          e.message[/error: ([^\n]*)/, 1] || e.message.lines.first.strip
        end
        [config, guest]
      end
      task.run { |config, guest| VMInfoWindow.open(config, @virt_cache.data(vm)&.disk_stat || [], guest) }
    end

    # Opens the maintenance menu for the selected VM. Resizing a disk image needs the VM shut
    # off, growing its root filesystem needs it running; the item the state rules out is
    # disabled. The menu is a snapshot, so a VM that changed state since gets an alert instead.
    # The health check is never disabled: a stopped VM is judged by its definition alone.
    # @return [void]
    def show_maintenance_popup
      vm = current_vm || return
      state = @virt_cache.state(vm)
      options = [['r', 'Resize disk image…', state == :shut_off ? {} : { disabled: 'shut the VM down first' }],
                 ['g', 'Grow root filesystem…', state == :running ? {} : { disabled: 'start the VM first' }],
                 ['h', 'Health check… (full scan: VM running)', {}]]
      Component::PickerWindow.open('Maintenance', options) do |key|
        state = @virt_cache.state(vm)
        if key == 'h'
          check_health(vm)
        elsif key == 'r' && state == :shut_off
          DiskResizeWindow.start(@virt_cache.virt, vm)
        elsif key == 'r'
          Component::ConfirmWindow.alert('Resize disk image', "Shut #{vm} down first: a running VM's disk image " \
                                                              'cannot be resized.')
        elsif key == 'g' && state == :running
          grow_root_filesystem(vm)
        elsif key == 'g'
          Component::ConfirmWindow.alert('Grow root filesystem', "Start #{vm} first: its root filesystem is grown " \
                                                                 'from inside the running guest.')
        end
      end
    end

    # Judges the VM's setup in the background (see {Virt::Health}) and opens {HealthWindow}
    # with the findings.
    # @param vm [String]
    # @return [void]
    def check_health(vm)
      virt = @virt_cache.virt
      BackgroundTask.new("Checking #{vm}'s health") { virt.health(vm) }.run { HealthWindow.open(vm, _1) }
    end

    # Checks how the VM's root filesystem would grow, asks the user to confirm the commands it
    # runs in the guest, then runs them behind a popup that cannot be canceled and reports the
    # new size. A guest whose layout or agent will not do gets the reason instead.
    # @param vm [String] a running VM
    # @return [void]
    def grow_root_filesystem(vm)
      virt = @virt_cache.virt
      check = BackgroundTask.new("Checking #{vm}'s root filesystem") do
        virt.root_grow_plan(vm)
      rescue Virt::GuestRootGrow::Refused, Virt::GuestAgent::Unavailable => e
        # virsh's own `error: …` line, not the `Command '…' failed` wrapper around it.
        e.message[/error: ([^\n]*)/, 1] || e.message
      end
      check.run do |plan|
        next Component::ConfirmWindow.alert("Cannot grow #{vm}'s root filesystem", plan) if plan.is_a?(String)

        fs = plan.filesystem
        Component::ConfirmWindow.confirm(
          "Grow #{vm}'s root filesystem?",
          "/ (#{fs.fstype} on #{plan.partition.name}, #{format_byte_size(plan.partition.size)}) grows by " \
          "#{format_byte_size(plan.growth)}, into the free space at the end of #{plan.disk.target}. This runs " \
          "#{plan.commands.map { _1[0][0] }.join(', ')} as root inside the guest, and cannot be canceled once it starts.",
          confirm: 'Grow'
        ) { run_root_grow(vm, plan) }
      end
    end

    # @param vm [String]
    # @param plan [Virt::GuestRootGrow::Plan]
    # @return [void]
    def run_root_grow(vm, plan)
      virt = @virt_cache.virt
      # Not cancelable: the agent runs each command to its end whatever virtui does.
      task = BackgroundTask.new("Growing #{vm}'s root filesystem", cancelable: false) do
        virt.grow_root(vm, plan)
        virt.guest_storage(vm).disk(plan.disk.target).partitions.last
      end
      task.run do |partition|
        # The partition's size, as `df` shows it; the filesystem's own total leaves out ext4's reserve.
        root = partition.filesystems.first
        Component::ConfirmWindow.alert("#{vm}'s / is now #{format_byte_size(partition.size)}",
                                       "#{format_byte_size(root.total - root.used)} of it free.")
      end
    end

    # Opens the memory menu for the selected VM: toggle auto-ballooning, or give it max
    # memory and disable ballooning. No-op (logs an error) if the VM isn't running.
    # @return [void]
    def show_memory_popup
      current_vm = self.current_vm || return
      state = @virt_cache.state(current_vm)
      if state != :running
        $log.error "'#{current_vm}' is not running"
        return
      end
      opts = [['b', 'toggle autoBallooning'], ['m', 'Max memory & disable autoballooning']]
      Component::PickerWindow.open('Memory', opts) do |key|
        if key == 'b' # toggle ballooning
          $log.info "Toggling balloning for '#{current_vm}'"
          @ballooning.toggle_enable(current_vm)
        elsif key == 'm'
          max_memory = @virt_cache.info(current_vm).max_memory
          $log.info "Disabling balooning & giving max mem (#{format_byte_size(max_memory)}) to '#{current_vm}'"
          @ballooning.enabled(current_vm, false)
          @virt_cache.set_actual(current_vm, max_memory)
        end
      end
    end

    # Opens the power menu for the selected VM: start, graceful shutdown, force off, soft
    # reboot or hard reset, and the magic-SysRq power-off and reboot between the two (see
    # {Virt::MagicSysRq}); the ones the VM's state or guest rules out are disabled. The menu is
    # a snapshot, so each action still logs an error if the VM changed state since.
    # @return [void]
    def show_power_popup
      current_vm = self.current_vm || return
      state = @virt_cache.state(current_vm)
      stopped = state == :shut_off ? {} : { disabled: 'VM not stopped' }
      running = state == :running ? {} : { disabled: 'VM not running' }
      refusal = sysrq_refusal(current_vm)
      sysrq = refusal.nil? ? {} : { disabled: refusal }
      opts = [['s', 'Start', stopped], ['o', 'shut dOwn gracefully', running],
              ['u', 'sync, remoUnt ro, power off (SysRq)', sysrq], ['O', 'force Off', running],
              ['r', 'reboot (soft)', running], ['b', 'sync, remount ro, reBoot (SysRq)', sysrq],
              ['R', 'Reset (hard)', running]]
      Component::PickerWindow.open('Power', opts) do |key|
        state = @virt_cache.state(current_vm)
        if %w[u b].include?(key)
          sysrq_power(current_vm, reboot: key == 'b')
        elsif key == 's' # start
          if state == :shut_off
            $log.info "Starting '#{current_vm}'"
            @virt_cache.virt.start(current_vm)
          else
            $log.error "'#{current_vm}' is already running"
          end
        elsif key == 'o' # shutdown gracefully
          if state == :running
            $log.info "Shutting down '#{current_vm}' gracefully"
            @virt_cache.virt.shutdown(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'O' # Force Off
          if state == :running
            $log.info "Force off '#{current_vm}'"
            @virt_cache.virt.force_off(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'r' # reboot
          if state == :running
            $log.info "Asking '#{current_vm}' to reboot"
            @virt_cache.virt.reboot(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'R' # reset
          if state == :running
            $log.info "Resetting '#{current_vm}' forcefully"
            @virt_cache.virt.reset(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        end
      end
    end

    # @param vm [String]
    # @return [String, nil] why the SysRq items cannot end this VM, or `nil` if they can
    def sysrq_refusal(vm)
      return 'VM not running' unless @virt_cache.running?(vm)

      entry = @virt_cache.cache(vm)
      Virt::MagicSysRq.refusal(entry.guest_os, entry.sysrq_mask)
    end

    # Syncs, remounts read-only and powers off or reboots the VM through magic SysRq, behind
    # a popup that cannot be canceled: a guest left after U has every filesystem read-only.
    # @param vm [String]
    # @param reboot [Boolean] B rather than O as the last key
    # @return [void]
    def sysrq_power(vm, reboot:)
      refusal = sysrq_refusal(vm)
      return $log.error("'#{vm}': no SysRq #{reboot ? 'reboot' : 'power-off'}: #{refusal}") unless refusal.nil?

      virt = @virt_cache.virt
      if reboot
        BackgroundTask.new("Rebooting #{vm} through SysRq", cancelable: false) { virt.sysrq_reboot(vm) }
                      .run { $log.info "'#{vm}' synced, remounted read-only and rebooted" }
      else
        BackgroundTask.new("Powering #{vm} off through SysRq", cancelable: false) { virt.sysrq_power_off(vm) }
                      .run { $log.info "'#{vm}' synced, remounted read-only and powered off" }
      end
    end

    # Builds a VM's overview row: state glyph, guest-OS marker, name, and (when running) a
    # balloon emoji with what the ballooning is doing ({BALLOON_GLYPHS}) and why, a "stale
    # data" turtle and the VM's address at the rule's right end.
    #
    #     ▶ 🐧 Ubuntu 🎈↑ raised to 2.6G: 70% used ───── 192.168.122.84 ─
    #     ▶ 🐧 Ubuntu 🎈-─────────────────────────────── 192.168.122.84 ─
    #     ⏹ ?  BASE────────────────────────────────────────────────────
    #
    # What sits on which side of the name is the rule to keep: left of it goes what the VM
    # *is* — facts that hold still while the user reads — and right of it what it is *doing*
    # right now. A live indicator on the left would shift the name column on every tick. The
    # address is right-aligned for the same reason: appearing or changing, it moves nothing.
    #
    # @param cache [Virt::Cache::VMCache] the VM's cache entry
    # @return [Row] the overview row
    def overview_row(cache)
      line = "#{format_domain_state(cache.data.state)} #{format_guest_os(cache.guest_os)} " \
             "#{screen.theme.vm_name(cache.info.name)}"
      words = tone = nil
      if cache.data.running?
        if cache.data.balloon?
          line += " \u{1F388}"
          standing = @ballooning.standing(cache.info.name)
          if standing.nil?
            # No ballooner until the first ballooning tick: nothing to say yet.
          elsif !@ballooning.enabled?(cache.info.name)
            line += 'x'
          else
            glyph, tone = BALLOON_GLYPHS[standing.kind]
            line += glyph.nil? ? '-' : screen.theme.public_send(tone, glyph)
            words = standing.brief unless standing.brief.empty?
          end
        end
        line += " \u{1F422}" if cache.stale?
      end
      address = cache.ip_address
      Row.new(cache.info.name, ->(width) { header(width, line, address, words:, tone:) })
    end

    # A guest │ host row: `caption` then the two cells, each as wide as {#column_width}.
    #
    #   split_row('Ubuntu', "    #{theme.ram('RAM')}") do |w|
    #     [usage_bar(w, guest_mem_usage, theme[:ram_vm]), usage_bar(w, host_mem_usage, theme[:ram])]
    #   end
    #   # renders:    RAM: 25%    2G ###------  7.9G │   9%  3.1G #--------    32G
    #
    # @param vm [String] the VM the row belongs to
    # @param caption [String] {ROW_CAPTION_WIDTH} - 1 columns wide, styling not counted
    # @yieldparam column_width [Integer] the width of one cell
    # @yieldreturn [Array(String, String)] the guest cell, then the host cell
    # @return [Row]
    def split_row(vm, caption, &cells)
      Row.new(vm, lambda do |width|
        guest, host = cells.call(column_width(width))
        "#{caption}:#{guest} #{COLUMN_SEPARATOR} #{host}"
      end)
    end

    # @param width [Integer] the list's text width
    # @return [Integer] the width of one {#split_row} cell: half of what the caption and the
    #   separator leave, never negative
    def column_width(width)
      [(width - ROW_CAPTION_WIDTH - " #{COLUMN_SEPARATOR} ".length) / 2, 0].max
    end

    # The guest-OS marker for a VM's overview line: what the VM's definition declares, as one
    # {GUEST_OS_GLYPHS} emoji padded to {GUEST_OS_WIDTH} cells.
    #
    # An undeclared OS draws a dim `?` rather than blank space, because `:unknown` is not a
    # neutral state here: {Virt::GuestOS#no_proc_meminfo?} is `!linux?`, so such a VM is never
    # asked for its swap level and quietly loses the guest half of its SWAP row — this marker
    # is the only thing on screen that says why. Same argument as {#swap_level_bar}'s dashes:
    # blank reads as *nothing there* when it means *nobody asked*.
    #
    # @param guest_os [Virt::GuestOS] what this VM's definition declares
    # @return [String] the marker, {GUEST_OS_WIDTH} cells wide, styling not counted
    def format_guest_os(guest_os)
      glyph = GUEST_OS_GLYPHS[guest_os.family] || screen.theme.frame('?')
      StyledString.parse(glyph).ljust(GUEST_OS_WIDTH).to_ansi
    end

    # The swap row, one per running VM that reports swap counters. Two cells, two questions:
    # the guest half is *occupancy*, drawn exactly like the RAM row above it so the two read
    # against each other; the host half is *I/O*, because guest swap writes land on the host's
    # disk.
    #
    #     RAM: 50%    4G ########---------  7.9G │  16%  5.1G ##---------------   32G
    #    SWAP: 43%  1.8G #######----------    4G │       3M/s ##-------------- ↕ 1.8G
    #    SWAP:  -        -----------------       │        0/s ---------------- ↕    0
    #          ^level, or unknown                        ^rate now      traffic since boot^
    #
    # Why the rate sits on the host side rather than beside the level: {#swap_io_bar}. Why an
    # unknown level is dashes rather than blank: {#swap_level_bar}. Two cells rather than
    # three figures in the guest cell because at ~100 columns a cell is ~42 characters, and a
    # level bar squeezed to ~10 loses the comparison against the RAM bar above it that makes
    # the level worth showing.
    #
    # Rendered whether or not the guest is swapping, so the warn coloring on the label rather
    # than the row's presence is what draws the eye: hiding the row at rest made every VM
    # below it jump a row on each swap burst. Absent *counters* are the one case that still
    # hides it, because that state never flips back while the reader is looking. (A guest
    # that reports a level but no counters therefore gets no row at all; no distro kernel
    # builds without `CONFIG_VM_EVENT_COUNTERS`, so that combination stays theoretical.)
    #
    # @param cache [Virt::Cache::VMCache] the VM's cache entry
    # @return [Row, nil] the swap row, or `nil` if the guest reports no swap counters
    def swap_row(cache)
      mem_stat = cache.data.mem_stat
      return nil unless mem_stat&.swap_data_available?

      theme = screen.theme
      rate = cache.swap_out_rate
      level = cache.guest_swap
      label = rate&.positive? ? theme.warn('SWAP') : theme.swap('SWAP')
      split_row(cache.info.name, "   #{label}") do |width|
        [swap_level_bar(width, level), swap_io_bar(width, rate, mem_stat)]
      end
    end

    # How full the guest's swap device is — the guest half of the swap row.
    #
    #    22%  1.8G #####--------------------     8G   <- 1.8G parked on an 8G device
    #      -        -------------------------         <- this guest cannot report a level
    #
    # Dashes rather than blank space for an unknown level, because blank reads as *nothing
    # parked* when it means *nobody asked*: the level needs a guest agent behind a persistent
    # virsh session (see {Virt::GuestAgent}), which plenty of guests will never have. Keeping
    # the cell occupied is also what keeps the rate in one column for every VM.
    #
    # @param width [Integer] width of one usage-bar column
    # @param level [ResourceUsage, nil] the guest's swap level, or `nil` if unavailable
    # @return [String] the rendered segment
    def swap_level_bar(width, level)
      theme = screen.theme
      return usage_bar(width, level, theme[:swap]) unless level.nil?

      # A full-width run of `rest_color` dashes: value 0 of 1.
      progress_bar('  -', '', width, 0, 1, theme[:swap])
    end

    # What the guest's swapping costs the host — the host half of the swap row: the rate now,
    # then the traffic since the guest booted.
    #
    #     3M/s ##-------------------- ↕  45M
    #
    # On the host side because that is what this column means everywhere else on the screen:
    # a guest's swap writes are the host's disk writes. The two lifetime counters are summed
    # for the same reason — `swap_out + swap_in` is the total traffic the host paid for, and
    # which direction it went is what the rate and the level already say.
    #
    # The gauge reads against {SWAP_RATE_FULL_SCALE} rather than a per-VM maximum, so two VMs'
    # bars mean the same thing.
    #
    # @param width [Integer] width of one usage-bar column
    # @param rate [Float, nil] bytes per second written to swap; `nil` on a first sample,
    #   where the counters are there but no interval has passed to diff them over
    # @param mem_stat [Virt::MemoryStat] the VM's memory stats, for the lifetime counters
    # @return [String] the rendered segment
    def swap_io_bar(width, rate, mem_stat)
      theme = screen.theme
      rate_text = rate.nil? ? '-' : format_byte_size(rate.round)
      # Right-aligned within the caption cell, one space clear of the bar — which puts the
      # figure in the same column the CPU/RAM rows end their own captions in.
      caption = "#{"#{rate_text.rjust(5)}/s".rjust(LABEL_WIDTH - 1)} "
      traffic = "#{theme.frame('↕')}#{format_byte_size(mem_stat.swap_out + mem_stat.swap_in).rjust(5)}"
      bar = Formatter.progress_bar((width - LABEL_WIDTH - SWAP_TOTALS_WIDTH - 1).clamp(0, nil),
                                   rate || 0, SWAP_RATE_FULL_SCALE, theme[:swap], theme[:frame])
      "#{caption}#{bar.to_ansi} #{traffic}"
    end

    # Draws a row header: `left` caption, then `words`, then a frame rule filling the rest of
    # `width`, with `right` inset near the rule's end (see {#overview_row}):
    #
    #     ▶ 🐧 vt-ubuntu 🎈↑ raised to 2.6G: 70% used ─────────── 192.168.123.239 ─
    #     ▶ 🐧 vt-ubuntu 🎈↑ raised to 2.6G… ─── 192.168.123.239 ─
    #
    # The room goes to `right` first: it is dropped whole, never truncated, when the rule has
    # no room for it, because a clipped address is a wrong address. `words` get what is left,
    # cut with `…`, and stay at least `───` clear of `right` so the two don't read as one.
    #
    # @param width [Integer] the list's text width
    # @param left [String] the caption (may contain styling)
    # @param right [String, nil] unstyled text to inset, or `nil` for a plain rule
    # @param words [String, nil] unstyled text after the caption; dropped when not even one
    #   character and the `…` fit
    # @param tone [Symbol, nil] the {Theme} reader that colors `words`
    # @return [String] the rendered header line
    def header(width, left, right = nil, words: nil, tone: nil)
      theme = screen.theme
      rule = width - StyledString.parse(left).display_width
      # Room for `─ right ─`: a space either side and at least one '─' before and after.
      right = nil if !right.nil? && rule < right.length + 4
      # ` words ───`, and then whatever `right` takes.
      room = rule - 5 - (right.nil? ? 0 : right.length + 3)
      if !words.nil? && room >= 2
        words = StyledString.plain(words).ellipsize(room)
        left = "#{left} #{theme.public_send(tone, words.to_s)} "
        rule -= words.display_width + 2
      end
      return left + theme.frame('─' * rule.clamp(0, nil)) if right.nil?

      "#{left}#{theme.frame('─' * (rule - right.length - 3))} #{right} #{theme.frame('─')}"
    end

    # Renders one labelled progress-bar segment: `left` caption, the bar, then `right`
    # caption, within `width` characters.
    #
    # @param left [String] left caption (padded to {LABEL_WIDTH} chars unless empty)
    # @param right [String] right caption (padded to 6 chars)
    # @param width [Integer] total width of the segment, in characters
    # @param value [Numeric] current value, for drawing the progress bar
    # @param max [Numeric] max value, for drawing the progress bar
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered segment, including ANSI color codes
    def progress_bar(left, right, width, value, max, color)
      Formatter.labelled_bar(width, left, right, value, max, color, screen.theme[:frame],
                             label_width: LABEL_WIDTH)
    end

    # Renders a {ResourceUsage} as a progress-bar segment captioned with percent used and
    # the used/total byte sizes; blank space if `mem_usage` is `nil`.
    #
    # @param width [Integer] the width of the segment, in characters
    # @param mem_usage [ResourceUsage, nil] the resource usage to render
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered segment
    def usage_bar(width, mem_usage, color)
      return ' ' * width if mem_usage.nil?

      progress_bar("#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                   format_byte_size(mem_usage.total), width, mem_usage.used, mem_usage.total, color)
    end

    # Maps a VM state to a colored status glyph.
    #
    # @param state [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
    # @return [String] the colored glyph for that state
    def format_domain_state(state)
      theme = screen.theme
      case state
      when :running  then theme.ok("\u{25B6}")
      when :shut_off then theme.off("\u{23F9}")
      when :paused   then theme.warn("\u{23F8}")
      else; theme.error('?')
      end
    end

    # How full the guest has filled one disk — the guest half of a disk row; the host half is
    # what the disk's image costs the host.
    #
    #    23%  3.4G #####--------------------    15G   <- the guest's filesystems on vda
    #      -        -------------------------         <- running, but the guest cannot say
    #                                                  <- stopped: nobody to ask
    #
    # The filesystems' total, not the disk's capacity: what the guest can still write.
    # Dashes for the reason {#swap_level_bar} draws them.
    #
    # @param width [Integer] width of one usage-bar column
    # @param cache [Virt::Cache::VMCache] the VM
    # @param target [String] the disk's host target, e.g. `vda`
    # @return [String] the rendered segment
    def guest_disk_bar(width, cache, target)
      return ' ' * width unless cache.data.running?

      theme = screen.theme
      usage = cache.guest_fs_usage&.[](target)
      return usage_bar(width, usage, theme[:disk_vm]) unless usage.nil?

      progress_bar('  -', '', width, 0, 1, theme[:disk_vm])
    end
  end
end
