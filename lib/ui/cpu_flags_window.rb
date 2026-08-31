# frozen_string_literal: true

module UI
  # The `h` help popup of {SystemWindow}: one paragraph per virtualization CPU flag
  # this host has, taken from the {CpuFlag} glossary — the glossary for the flag list
  # the CPU summary line shows.
  #
  # Content is a {Tuile::Component::TextView}, not a {Tuile::Component::List}: the
  # explanations are prose, and a `List` row that overflows is *ellipsized*, which
  # silently ate the end of every description. A `TextView` word-wraps instead, so
  # the popup's width only decides how tall the text gets.
  #
  # UI-thread-confined.
  class CpuFlagsWindow < Tuile::Component::Window
    include Tuile

    # Wider than the default {Fraction::HALF}: this is prose, and a wider box means
    # fewer wrapped rows to scroll through.
    # @return [Fraction]
    SIZE = Fraction.new(0.7, 0.7)

    # @param flags [Set<String>] the host's CPU flags, from {System::Info#cpu_flags}
    def initialize(flags = Set.new)
      super('CPU virtualization flags')
      @flags = flags
      @view = Component::TextView.new
      self.content = @view
      self.footer_text = 'q/ESC to close'
      rebuild
    end

    # @return [Set<String>] the host CPU flags currently explained
    attr_reader :flags

    # Re-renders the explanations for a new set of host flags.
    # @param flags [Set<String>] the host's CPU flags, from {System::Info#cpu_flags}
    # @return [void]
    def flags=(flags)
      @flags = flags
      rebuild
    end

    # Opens the window as a modal popup, sized {SIZE}.
    #
    # @param flags [Set<String>] the host's CPU flags, from {System::Info#cpu_flags}
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(flags)
      Tuile::Component::Popup.new(content: new(flags), declared_size: SIZE).open
    end

    protected

    # Re-renders when the theme changes, so the flag names follow the new palette.
    # @return [void]
    def on_theme_changed
      super
      rebuild
    end

    private

    # Renders one blank-line-separated paragraph per present flag: the flag name in
    # the CPU accent color, then a colon and its description.
    # @return [void]
    def rebuild
      theme = screen.theme
      @view.text = CpuFlag.present_in(@flags)
                          .map { |it| theme.cpu(it.name) + theme.hint(": #{it.description}") }
                          .join("\n\n")
    end
  end
end
