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
              free_page_reporting: 'Fix: turn on free page reporting…',
              discard: 'Fix: pass discards to the image…' }.freeze

    # The remedies that run `virt-xml`; their buttons say so while it is missing.
    # @return [Array<Symbol>]
    VIRT_XML_FIXES = %i[free_page_reporting discard].freeze

    # One finding's components.
    # @!attribute [r] finding
    #   @return [Virt::Health::Finding]
    # @!attribute [r] head
    #   @return [Tuile::Component::Label] the mark and the subject
    # @!attribute [r] text
    #   @return [Tuile::Component::Label] the finding and its fix, wrapped
    Entry = Data.define(:finding, :head, :text)
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
      paint
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
      paint
    end

    private

    # @return [Integer] the head column: a margin, the mark, a space, the subject, two spaces
    def head_width = @subject_width + 5

    # @param finding [Virt::Health::Finding]
    # @return [Entry]
    def add_entry(finding)
      head = Component::Label.new
      text = Component::Label.new(wrap: true)
      body = Component::Layout::Vertical.new
      body.add(text, Component::Layout::Auto[])
      caption = FIXES[finding.remedy]
      if VIRT_XML_FIXES.include?(finding.remedy) && !@virt.virt_xml_available?
        caption = "#{caption.delete_suffix('…')} (please install virt-xml for this to work)"
      end
      button = caption && Component::Button.new(caption) { fix(finding) }
      body.add(button, Component::Layout::Fixed[1]) if button
      row = Component::Layout::Horizontal.new
      row.add(head, Component::Layout::Fixed[head_width])
      row.add(body, Component::Layout::Expand[1], cross: Component::Layout::Auto[])
      @rows.add(row, Component::Layout::Auto[])
      Entry.new(finding, head, text)
    end

    # Writes the heads and the texts in the current theme's colors.
    # @return [void]
    def paint
      theme = screen.theme
      @entries.each do |entry|
        finding = entry.finding
        entry.head.text = " #{mark(theme, finding.severity)} #{finding.subject}"
        entry.text.text = [finding.text, finding.fix && theme.hint(finding.fix)].compact.join("\n")
      end
    end

    # @param delta [Integer] rows; negative scrolls up, and the scroller clamps the bottom
    # @return [void]
    def scroll_by(delta)
      @scroller.scroll_top_row = [@scroller.scroll_top_row + delta, 0].max
    end

    # Closes the dialog, which the fix would leave stale, then starts the fix's flow.
    # @param finding [Virt::Health::Finding] one whose remedy is in {FIXES}
    # @return [void]
    def fix(finding)
      close
      virt = @virt
      vm = @vm
      case finding.remedy
      when :grow_root then VMPane::RootGrower.new(virt, vm).start
      when :free_page_reporting
        edit_definition('free page reporting', '--memballoon freePageReporting=on',
                        confirm: "Turn on free page reporting for '#{vm}'?", confirm_button: 'Turn on',
                        progress: "Turning on free page reporting for '#{vm}'",
                        done: "Free page reporting is on for '#{vm}'") { virt.enable_free_page_reporting(vm) }
      when :discard
        target = finding.subject
        edit_definition("#{target}'s discards", "target=#{target} --disk discard=unmap",
                        confirm: "Pass #{target}'s discards to its image for '#{vm}'?", confirm_button: 'Pass',
                        progress: "Setting discard=unmap on #{target} of '#{vm}'",
                        done: "#{target} of '#{vm}' passes discards to its image") { virt.enable_discard(vm, target) }
      end
    end

    # Asks the user to confirm a `virt-xml` edit of the definition, then makes it behind a
    # progress dialog; says to install `virt-xml` instead while it is missing.
    # @param what [String] what the edit turns on, for the missing-`virt-xml` alert
    # @param args [String] `virt-xml`'s arguments after the VM name, as the confirmation shows them
    # @param confirm [String] the confirmation's caption
    # @param confirm_button [String]
    # @param progress [String] the progress dialog's caption
    # @param done [String] the closing alert's caption
    # @yield on a {BackgroundTask}'s thread: the edit, through the backend
    # @return [void]
    def edit_definition(what, args, confirm:, confirm_button:, progress:, done:, &edit)
      vm = @vm
      unless @virt.virt_xml_available?
        return Component::ConfirmDialog.alert('Please install virt-xml',
                                              "virtui sets #{what} through virt-xml, which is not on the PATH: " \
                                              'sudo apt install virt-install')
      end

      Component::ConfirmDialog.confirm(
        confirm,
        "This runs virt-xml '#{vm}' --edit #{args}, which changes the definition '#{vm}' reads at its next " \
        "start. It takes effect once '#{vm}' is powered off and on: a reboot from inside the guest keeps the old " \
        'device.',
        confirm: confirm_button
      ) do
        BackgroundTask.new(progress, cancelable: false, &edit).run do
          Component::ConfirmDialog.alert(done, 'From its next power-on. Pick Health check again to see it.')
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
