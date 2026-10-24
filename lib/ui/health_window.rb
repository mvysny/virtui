# frozen_string_literal: true

module UI
  # The `M` → Health check popup of {VMPane}: one line per {Virt::Health::Finding}, its fix
  # on a hint-colored line beneath.
  #
  #   ┌─ vt-ubuntu health ─────────────────────────────────────────────────┐
  #   │ ✓ balloon  virtio, free page reporting                             │
  #   │ ✓ agent    connected                                               │
  #   │ ✓ vda      discards reach the image                                │
  #   │ · vdb      shared with other VMs, and the host drops its discards  │
  #   │            virt-xml vt-ubuntu --edit target=vdb --disk discard=unmap, …│
  #   │ ! /mnt/hc  hccrypt (dm-0) blocks discard                           │
  #   │            if it is LUKS: add `discard` to its /etc/crypttab options, …│
  #   │ ✓ trim     fstrim.timer enabled                                    │
  #   └──────────────────────────────────────────────────── q/ESC to close ─┘
  #
  # `✓` ok, `·` a note, `!` a warning, `–` not checked. A snapshot of the moment it was
  # asked for.
  #
  # UI-thread-confined.
  class HealthWindow < Tuile::Component::Window
    include Tuile

    # Like {VMInfoWindow::SIZE}, shorter: a VM with a handful of disks runs to ~15 rows.
    # @return [Fraction]
    SIZE = Fraction.new(0.7, 0.6)

    # @param vm [String] VM name, for the caption
    # @param health [Virt::Health]
    def initialize(vm, health)
      super("#{vm} health")
      @health = health
      @view = Component::TextView.new
      self.content = @view
      self.footer_text = 'q/ESC to close'
      rebuild
    end

    # Opens the window as a modal popup, sized {SIZE}.
    #
    # @param vm [String] VM name
    # @param health [Virt::Health]
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(vm, health)
      Tuile::Component::Popup.new(content: new(vm, health), declared_size: SIZE).open
    end

    protected

    # @return [void]
    def handle_theme_changed
      super
      rebuild
    end

    private

    # @return [void]
    def rebuild
      theme = screen.theme
      findings = @health.findings
      width = findings.map { _1.subject.length }.max.to_i
      @view.text = findings.flat_map do |finding|
        line = "#{mark(theme, finding.severity)} #{finding.subject.ljust(width)}  #{finding.text}"
        finding.fix ? [line, theme.hint("#{' ' * (width + 4)}#{finding.fix}")] : [line]
      end.join("\n")
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
