# frozen_string_literal: true

module UI
  # The `M` → Health check dialog of {VMPane}: one row per {Virt::Health::Finding}, its fix in
  # hint color beneath, and a Fix button under a finding whose fix virtui can run itself:
  #
  #   HealthDialog.new(virt, 'vt-ubuntu', virt.health('vt-ubuntu')).open
  #
  #   ┌vt-ubuntu health────────────────────────────────────────────────┐
  #   │ · balloon  virtio, no free page reporting: memory the guest    █
  #   │            frees stays with it until the balloon takes it      █
  #   │            virt-xml vt-ubuntu --edit --memballoon              █
  #   │            freePageReporting=on, then power it off and on      █
  #   │            [ Fix: turn on free page reporting… ]               █
  #   │ ✓ agent    connected                                           █
  #   │ ! /mnt/hc  hccrypt (dm-0) blocks discard                       █
  #   │            if it is LUKS: add `discard` to its /etc/crypttab   █
  #   │            options, then reboot the guest                      █
  #   │ · vda      28G unused after vda1                               █
  #   │            M → Grow root filesystem                            ░
  #   └q/ESC to close──────────────────────────────────────────────────┘
  #
  # `✓` ok, `·` a note, `!` a warning, `–` not checked. A snapshot of the moment it was asked
  # for, so a Fix button closes it before its flow starts; picking Health check again shows the
  # result.
  #
  # Tab moves between the buttons; PgUp/PgDn, the arrows and the wheel scroll.
  #
  # == Implementation details
  # Tuile wraps no text it does not also scroll, so each finding is wrapped here, at the text
  # column's width, and its row count handed to the layout and the {Tuile::Component::Scroller}
  # (tuile#73). The bar stays `:visible`, so the width never depends on the row count.
  #
  # UI-thread-confined.
  class HealthDialog < Tuile::Component::Dialog
    include Tuile

    # Like {VMInfoDialog::SIZE}, shorter: a VM with a handful of disks runs to ~15 rows.
    # @return [Fraction]
    SIZE = Fraction.new(0.7, 0.6)

    # The Fix buttons' captions, by {Virt::Health::Finding#remedy}; a remedy not here gets no
    # button.
    # @return [Hash{Symbol => String}]
    FIXES = { grow_root: 'Fix: grow root filesystem…',
              free_page_reporting: 'Fix: turn on free page reporting…' }.freeze

    # The free-page-reporting button's caption while `virt-xml`, which it runs, is missing.
    # @return [String]
    NO_VIRT_XML = 'Fix: turn on free page reporting (please install virt-xml for this to work)'

    # The columns a {Tuile::Component::Scroller} keeps for its bar and the gap beside it.
    # @return [Integer]
    SCROLLBAR_COLUMNS = 2

    # One finding's components.
    # @!attribute [r] finding
    #   @return [Virt::Health::Finding]
    # @!attribute [r] row
    #   @return [Tuile::Component::Layout::Horizontal] the head, then the body
    # @!attribute [r] head
    #   @return [Tuile::Component::Label] the mark and the subject
    # @!attribute [r] body
    #   @return [Tuile::Component::Layout::Vertical] the text, then the button
    # @!attribute [r] text
    #   @return [Tuile::Component::Label] the finding and its fix, wrapped
    # @!attribute [r] button
    #   @return [Tuile::Component::Button, nil]
    Entry = Data.define(:finding, :row, :head, :body, :text, :button)
    private_constant :Entry

    # @param virt [Virt::Virsh, Virt::VMEmulator] the backend a Fix button runs through
    # @param vm [String] VM name
    # @param health [Virt::Health]
    def initialize(virt, vm, health)
      super("#{vm} health", declared_size: SIZE, footer_text: 'q/ESC to close')
      @virt = virt
      @vm = vm
      @subject_width = health.findings.map { _1.subject.length }.max.to_i
      @rows = Component::Layout::Vertical.new
      @scroller = Component::Scroller.new(@rows)
      self.content = @scroller
      self.scrollbar = true
      @entries = health.findings.map { add_entry(_1) }
      @wrapped_at = nil
      paint_heads
    end

    # PgUp/PgDn scroll half a page, the arrows a row: the {Tuile::Component::Scroller} claims
    # no keys of its own.
    # @param key [String]
    # @return [Boolean]
    def handle_key?(key)
      case key
      when Keys::PAGE_UP then @scroller.scroll_half_page_up
      when Keys::PAGE_DOWN then @scroller.scroll_half_page_down
      when *Keys::UP_ARROWS then scroll_by(-1)
      when *Keys::DOWN_ARROWS then scroll_by(1)
      else return super
      end
      true
    end

    protected

    # @return [void]
    def handle_theme_changed
      super
      paint_heads
      @wrapped_at = nil
      invalidate_layout
    end

    # @return [void]
    def relayout
      super
      width = content_rect.width - SCROLLBAR_COLUMNS - head_width
      wrap(width) unless width == @wrapped_at
    end

    private

    # @return [Integer] the head column: a margin, the mark, a space, the subject, two spaces
    def head_width = @subject_width + 5

    # @param finding [Virt::Health::Finding]
    # @return [Entry]
    def add_entry(finding)
      head = Component::Label.new
      text = Component::Label.new
      body = Component::Layout::Vertical.new
      body.add(text)
      caption = FIXES[finding.remedy]
      caption = NO_VIRT_XML if finding.remedy == :free_page_reporting && !@virt.virt_xml_available?
      button = caption && Component::Button.new(caption) { fix(finding.remedy) }
      body.add(button) if button
      row = Component::Layout::Horizontal.new
      row.add(head, Component::Layout::Fixed[head_width])
      row.add(body, Component::Layout::Expand[1])
      @rows.add(row)
      Entry.new(finding, row, head, body, text, button)
    end

    # @return [void]
    def paint_heads
      theme = screen.theme
      @entries.each { _1.head.text = " #{mark(theme, _1.finding.severity)} #{_1.finding.subject}" }
    end

    # Wraps every finding at `width` and sizes the rows to it.
    # @param width [Integer] the text column's; at most 0 leaves the lines unwrapped
    # @return [void]
    def wrap(width)
      @wrapped_at = width
      theme = screen.theme
      @scroller.content_rows = @entries.sum do |entry|
        finding = entry.finding
        lines = StyledString.parse(finding.text).wrap(width)
        lines += StyledString.parse(theme.hint(finding.fix)).wrap(width) if finding.fix
        entry.text.text = lines.map(&:to_ansi).join("\n")
        entry.body.constrain(entry.text, Component::Layout::Fixed[lines.size])
        rows = lines.size + (entry.button ? 1 : 0)
        @rows.constrain(entry.row, Component::Layout::Fixed[rows])
        rows
      end
    end

    # @param delta [Integer] rows; negative scrolls up
    # @return [void]
    def scroll_by(delta)
      bottom = [@scroller.content_rows - @scroller.viewport_rows, 0].max
      @scroller.scroll_top_row = (@scroller.scroll_top_row + delta).clamp(0, bottom)
    end

    # Closes the dialog, which the fix would leave stale, then starts the fix's flow.
    # @param remedy [Symbol] one of {FIXES}' keys
    # @return [void]
    def fix(remedy)
      close
      case remedy
      when :grow_root then VMPane::RootGrower.new(@virt, @vm).start
      when :free_page_reporting then turn_on_free_page_reporting
      end
    end

    # Asks the user to confirm the definition edit, then makes it behind a progress dialog.
    # @return [void]
    def turn_on_free_page_reporting
      virt = @virt
      vm = @vm
      unless virt.virt_xml_available?
        return Component::ConfirmDialog.alert('Please install virt-xml',
                                              'virtui turns free page reporting on through virt-xml, which is not ' \
                                              'on the PATH: sudo apt install virt-install')
      end

      Component::ConfirmDialog.confirm(
        "Turn on free page reporting for '#{vm}'?",
        "This runs virt-xml '#{vm}' --edit --memballoon freePageReporting=on, which changes the definition " \
        "'#{vm}' reads at its next start. It takes effect once '#{vm}' is powered off and on: a reboot from inside " \
        'the guest keeps the old device.',
        confirm: 'Turn on'
      ) do
        task = BackgroundTask.new("Turning on free page reporting for '#{vm}'", cancelable: false) do
          virt.enable_free_page_reporting(vm)
        end
        task.run do
          Component::ConfirmDialog.alert("Free page reporting is on for '#{vm}'",
                                         'From its next power-on. Pick Health check again to see it.')
        end
      end
    end

    # @param theme [Theme]
    # @param severity [Symbol]
    # @return [String] one colored character
    def mark(theme, severity)
      case severity
      when :ok then theme.ok('✓')
      when :warning then theme.warn('!')
      when :note then '·'
      else theme.hint('–')
      end
    end
  end
end
