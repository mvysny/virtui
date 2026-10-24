# frozen_string_literal: true

module UI
  # The `M` → Resize disk image dialog: asks for one stopped VM's disk's new size, and hands
  # it to a block on Enter.
  #
  #   DiskResizeWindow.open('vt-ubuntu', 'vda', volume) { |capacity| resize(capacity) }
  #
  #   ┌Resize vt-ubuntu's vda─────────────────────────────────┐
  #   │Image     /var/lib/libvirt/images/vt-ubuntu.qcow2      │
  #   │Size      14G, 579M of it on the host                  │
  #   │Pool      default, 89G free                            │
  #   │                                                       │
  #   │New size  +10G                                         │
  #   │          → 24G                                        │
  #   └─────────────────────── Enter to resize · ESC to cancel┘
  #
  # The field takes `+10G` (grow by) or `20G` (the new size), see {.parse_size}; the row under
  # it shows the outcome as it is typed, or why it cannot be. Grows only. Growing past the
  # pool's free space is warned about, not refused: the image is sparse, so it costs nothing
  # until the guest writes.
  #
  # UI-thread-confined.
  class DiskResizeWindow < Tuile::Component::Window
    include Tuile

    # The caption column, `New size` plus two spaces.
    CAPTION_WIDTH = 10

    # Border rows plus three info rows, a blank, the field and the outcome.
    HEIGHT = 8

    # The narrowest box: the footer has to fit.
    MIN_WIDTH = 50

    # Whole MiB, which every partitioner aligns to and every image format can hold.
    GRANULE = 1.MiB

    # What the alert after a resize tells the user: the guest's side is still to do.
    GUEST_HINT = "The partitions and filesystems inside are as they were. A cloud image grows its root \
filesystem at the next boot; otherwise start the VM and grow it with M, Grow root filesystem."

    # @param vm [String] the VM's name
    # @param target [String] the disk's target, e.g. `vda`
    # @param volume [Virt::Volume] the disk's image
    # @yield [capacity] on Enter with a valid size; the popup has closed by then
    # @yieldparam capacity [Integer] the new size, in bytes
    # @raise [ArgumentError] without a block
    def initialize(vm, target, volume, &on_resize)
      raise ArgumentError, 'block required' unless on_resize

      super("Resize #{vm}'s #{target}")
      @volume = volume
      @on_resize = on_resize
      @field = Component::TextField.new
      # ESC goes on to the popup, which closes, rather than merely blurring the field.
      @field.escape_clears_focus = false
      @field.value_change_mode = :eager
      @field.on_value_change { show_outcome }
      @field.on_enter { resize }
      @info = Component::Label.new
      @size_caption = Component::Label.new
      @outcome = Component::Label.new
      row = Component::Layout::Horizontal.new
      row.add(@size_caption, Component::Layout::Fixed[CAPTION_WIDTH])
      row.add(@field, Component::Layout::Expand[1])
      box = Component::Layout::Vertical.new
      box.add(@info, Component::Layout::Fixed[4])
      box.add(row, Component::Layout::Fixed[1])
      box.add(@outcome, Component::Layout::Fixed[1])
      self.content = box
      self.footer_text = 'Enter to resize · ESC to cancel'
      rebuild
    end

    # @return [Tuile::Component::TextField] the size field
    attr_reader :field

    # @return [Virt::Volume] the image being resized
    attr_reader :volume

    # Opens the dialog as a modal popup, the size field focused.
    #
    # @param vm [String] see {#initialize}
    # @param target [String] see {#initialize}
    # @param volume [Virt::Volume] see {#initialize}
    # @yield [capacity] see {#initialize}
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(vm, target, volume, &)
      window = new(vm, target, volume, &)
      # The border, plus a spare column so the path does not touch it.
      width = (window.volume.path.length + CAPTION_WIDTH + 3).clamp(MIN_WIDTH..)
      popup = Component::Popup.new(content: window, declared_size: Size.new(width, HEIGHT)).open
      window.field.focus
      popup
    end

    # The whole `M` → Resize disk image flow for a stopped VM: reads its disks behind a
    # progress popup, lets the user pick one when there are several, opens the dialog, then
    # resizes behind a popup that cannot be canceled and says what is left to do.
    #
    #   DiskResizeWindow.start(virt_cache.virt, 'vt-ubuntu')
    #
    # Offers the file-backed disks in a storage pool; a disk in none gets the command to run by
    # hand instead, since virtui does not escalate.
    #
    # @param virt [Virt::Virsh, Virt::VMEmulator] the backend
    # @param vm [String] the VM's name; should be shut off, or the resize fails on QEMU's lock
    # @return [void]
    def self.start(virt, vm)
      task = BackgroundTask.new("Reading #{vm}'s disks") do
        disks = virt.domain_config(vm).disks.select { _1.device == 'disk' && _1.type == 'file' && _1.source }
        disks.map { [_1, virt.volume(_1.source)] }
      end
      task.run { |disks| pick(virt, vm, disks) }
    end

    # @param virt [Virt::Virsh, Virt::VMEmulator]
    # @param vm [String]
    # @param disks [Array<Array(Virt::DomainConfig::Disk, Virt::Volume)>] each with its volume,
    #   `nil` when in no pool
    # @return [void]
    private_class_method def self.pick(virt, vm, disks)
      pooled = disks.reject { _1[1].nil? }
      if pooled.empty?
        message = disks.map { "#{_1[0].target} is in no storage pool: with #{vm} stopped, sudo qemu-img resize #{_1[0].source} <size>" }
        Component::ConfirmWindow.alert("#{vm}: nothing to resize",
                                       message.empty? ? "#{vm} has no disk image file." : message.join("\n"))
        return
      end

      open_for = ->((disk, volume)) { self.open(vm, disk.target, volume) { resize(virt, vm, disk.target, volume, _1) } }
      return open_for.call(pooled.first) if pooled.size == 1

      options = pooled.each_with_index.map do |(disk, volume), i|
        [(i + 1).to_s, "#{disk.target}  #{format_byte_size(volume.capacity)}  #{volume.path}"]
      end
      Component::PickerWindow.open('Which disk?', options) { open_for.call(pooled[_1.to_i - 1]) }
    end

    # @param virt [Virt::Virsh, Virt::VMEmulator]
    # @param vm [String]
    # @param target [String]
    # @param volume [Virt::Volume]
    # @param capacity [Integer] bytes
    # @return [void]
    private_class_method def self.resize(virt, vm, target, volume, capacity)
      size = format_byte_size(capacity)
      # Not cancelable: a cancel could not stop libvirtd's qemu-img, only lie that it had.
      task = BackgroundTask.new("Resizing #{vm}'s #{target} to #{size}", cancelable: false) do
        virt.resize_volume(volume.path, capacity)
      end
      task.run { Component::ConfirmWindow.alert("#{vm}'s #{target} is now #{size}", GUEST_HINT) }
    end

    # Reads a typed size: `+10G` grows by 10 GiB, `20G` asks for 20 GiB.
    #
    #   DiskResizeWindow.parse_size('+10G', 14.GiB)   # => 24 GiB
    #   DiskResizeWindow.parse_size('1.5T', 14.GiB)   # => 1.5 TiB
    #   DiskResizeWindow.parse_size('10G', 14.GiB)    # raises: grows only
    #
    # Units are binary, as everywhere on screen: `K`, `M`, `G`, `T`, optionally `iB`, any case.
    # A bare number is refused rather than read as bytes, which is what `virsh` would make of
    # it and nobody types. Rounded down to whole MiB.
    #
    # @param text [String] what the user typed
    # @param current [Integer] the disk's capacity now, in bytes
    # @return [Integer] the new capacity, in bytes, above `current`
    # @raise [ArgumentError] with a message for the user, if `text` is no size or not a growth
    def self.parse_size(text, current)
      match = text.strip.match(/\A(\+)?\s*(\d+(?:\.\d+)?)\s*([KMGT])(?:iB)?\z/i)
      raise ArgumentError, '+10G grows by 10 GiB, 20G sets 20 GiB' if match.nil?

      plus, number, unit = match.captures
      bytes = (Rational(number) * (1024**' KMGT'.index(unit.upcase))).floor
      capacity = (plus ? current + bytes : bytes) / GRANULE * GRANULE
      raise ArgumentError, "grows only: #{format_byte_size(current)} is its size now" if capacity <= current

      capacity
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
      @theme = screen.theme
      v = @volume
      @info.text = [line('Image', v.path),
                    line('Size', "#{format_byte_size(v.capacity)}, #{format_byte_size(v.allocation)} of it on the host"),
                    line('Pool', "#{v.pool}, #{format_byte_size(v.pool_available)} free")].join("\n")
      @size_caption.text = @theme.hint('New size'.ljust(CAPTION_WIDTH))
      show_outcome
    end

    # @return [void]
    def show_outcome
      capacity = self.class.parse_size(@field.text, @volume.capacity)
      growth = capacity - @volume.capacity
      text = "→ #{format_byte_size(capacity)}"
      text += @theme.error(" — more than the pool's #{format_byte_size(@volume.pool_available)} free") if growth > @volume.pool_available
      @outcome.text = (' ' * CAPTION_WIDTH) + text
    rescue ArgumentError => e
      @outcome.text = (' ' * CAPTION_WIDTH) + (@field.text.strip.empty? ? @theme.hint(e.message) : @theme.error(e.message))
    end

    # @return [void]
    def resize
      capacity = begin
        self.class.parse_size(@field.text, @volume.capacity)
      rescue ArgumentError
        nil # the outcome row already says why
      end
      return if capacity.nil?

      parent.close if parent.is_a?(Component::Popup)
      @on_resize.call(capacity)
    end

    # @param caption [String]
    # @param value [String]
    # @return [String] `value` behind a hint-colored caption, padded to {CAPTION_WIDTH}
    def line(caption, value)
      @theme.hint(caption.ljust(CAPTION_WIDTH)) + value
    end
  end
end
