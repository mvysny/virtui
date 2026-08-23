# frozen_string_literal: true

module Virt
  class VMEmulator
    # A single simulated VM. When started, its guest-app memory usage slowly ramps up to
    # `started_initial_apps` (via an {Interpolator}), and `disk_caches` sits around 1 GiB.
    # Memory figures are recomputed on demand by {#to_mem_stat}.
    class VM
      # Minimum memory we pretend the guest apps need.
      # @return [Integer]
      MIN_APP_MEMORY = 128.MiB
      # Memory the kernel+BIOS reserve — the gap between {MemoryStat}'s `actual` and `available`.
      # @return [Integer]
      BIOS_KERNEL = 128.MiB
      # Smallest allowed value of {MemoryStat}'s `actual`.
      # @return [Integer]
      MIN_ACTUAL = MIN_APP_MEMORY + BIOS_KERNEL

      # Creates a VM (initially shut off).
      #
      # @param info [DomainInfo] static VM configuration
      # @param initial_actual [Integer] {MemoryStat}'s `actual` when the VM is started, in bytes
      # @param started_initial_apps [Integer] guest-app memory the VM ramps to after start,
      #   in bytes; change it later via {#memory_app=}
      # @raise [RuntimeError] if any size is below its minimum (`max_memory`/`initial_actual`
      #   under 128 MiB, or `started_initial_apps` under {MIN_APP_MEMORY})
      def initialize(info, initial_actual, started_initial_apps)
        raise "max_memory must be #{MIN_ACTUAL} or higher" if info.max_memory < 128.MiB
        raise "initial_actual must be #{MIN_ACTUAL} or higher" if initial_actual < 128.MiB
        raise "initial mem for apps must be at least #{MIN_APP_MEMORY}" if started_initial_apps < MIN_APP_MEMORY

        @info = info
        @started_initial_apps = started_initial_apps
        @initial_actual = initial_actual
        @disk_caches = 1.GiB
        @swap_out_rate = 0
        @swap_out_base = 0
        @swap_out_since = Time.now
        @swap_total = 4.GiB
        @guest_os = VMEmulator::LINUX
        @startup_seconds = 10
        @shutdown_seconds = 5
        # How many seconds it will take for the VM to decrease its active memory.
        @decrease_active_seconds = 5
      end

      # Convenience constructor: a 1-CPU VM whose initial app usage is half of `actual`.
      #
      # @param name [String] VM name
      # @param actual [Integer] initial {MemoryStat} `actual`, in bytes
      # @param max_actual [Integer] the VM's maximum memory, in bytes (defaults to a large
      #   multiple of `actual`)
      # @return [VM] the new VM
      def self.simple(name, actual: 2.GiB, max_actual: actual * 256)
        VM.new(DomainInfo.new(name, 1, max_actual), actual, actual / 2)
      end

      # @return [String] the VM name
      def name
        info.name
      end

      # @return [Integer] bytes per second the simulated guest writes to swap; 0 (the
      #   default) is a guest with a swap device it isn't touching
      attr_reader :swap_out_rate

      # @return [GuestOS] what this simulated VM's definition declares ({VMEmulator::LINUX} by
      #   default, matching the guest that answers `/proc/meminfo` in {#swap}); set it to
      #   {VMEmulator::WINDOWS} or {GuestOS::UNKNOWN} to simulate a guest {Cache} won't ask
      attr_accessor :guest_os

      # @return [Integer, nil] size of the simulated guest's swap device (4 GiB by default);
      #   `nil` simulates a guest whose level cannot be read at all — no guest agent, or no
      #   swap configured — which is the other half {Virt::GuestAgent#swap} can return
      attr_accessor :swap_total

      # Sets how fast the simulated guest writes to swap, from now on.
      #
      #   vm.swap_out_rate = 3.MiB   # {#swap_out_total} now climbs by 3 MiB per second
      #
      # @param bytes_per_second [Integer] the new rate
      def swap_out_rate=(bytes_per_second)
        # Bank what has accrued so far, so a rate change never walks the counter backwards.
        # A real pswpout only ever resets by rebooting, and the controller reads a decrease
        # as exactly that (see {Cache::VMCache#swap_out_rate}).
        @swap_out_base = swap_out_total
        @swap_out_since = Time.now
        @swap_out_rate = bytes_per_second
      end

      # The guest's cumulative swap-out counter: {#swap_out_rate} integrated over the time
      # it has been set, restarting from 0 on every {#start} — which is what a real guest's
      # per-boot `pswpout` does.
      #
      # @return [Integer] bytes written to swap since {#start}, or 0 when not running
      def swap_out_total
        return 0 unless running?

        @swap_out_base + (@swap_out_rate * (Time.now - @swap_out_since)).to_i
      end

      # The simulated guest's swap occupancy, as {Virt::GuestAgent#swap} would report it.
      #
      #   vm.swap.to_s   # => "1.2G/4G (30%)"
      #
      # Everything written out, capped by the device: the emulator never faults pages back in
      # (its `swap_in` stays 0), so written-out is parked.
      #
      # @return [ResourceUsage, nil] swap used out of {#swap_total}; `nil` when not running,
      #   or when {#swap_total} is `nil`
      def swap
        return nil if !running? || @swap_total.nil?

        ResourceUsage.of(@swap_total, swap_out_total.clamp(0, @swap_total))
      end

      # @return [DomainInfo] static VM configuration
      attr_reader :info
      # @return [Integer] guest-app memory the VM ramps to after start, in bytes; change it
      #   via {#memory_app=}
      attr_reader :started_initial_apps

      # @return [Boolean] whether the VM is currently running (or still within its
      #   shutdown grace period)
      def running?
        !@started_at.nil? && (@shut_down_at.nil? || Time.now - @shut_down_at < @shutdown_seconds)
      end

      # "Starts" this VM: app memory begins ramping up to {#started_initial_apps}.
      #
      # @return [void]
      # @raise [RuntimeError] if the VM is already running
      def start
        raise 'Already running' if running?

        @started_at = Time.now
        @shut_down_at = nil
        @swap_out_base = 0
        @swap_out_since = @started_at
        @actual = Interpolator::Const.new(@initial_actual)
        # Mem used by guest apps. This doesn't include disk_caches.
        # This can be higher than 'MemoryStat.available' - we pretend that the rest of the app memory
        # is swapped out.
        @mem_apps = Interpolator::Linear.from_now(0, started_initial_apps, @startup_seconds)
      end

      # @return [Float, nil] uptime in seconds, or `nil` if shut down
      def uptime
        running? ? Time.now - @started_at : nil
      end

      # Initiates a graceful shutdown: app memory ramps down to zero over the grace period.
      #
      # @return [void]
      # @raise [RuntimeError] if the VM is not running
      def shut_down
        check_running

        @shut_down_at = Time.now
        @mem_apps = Interpolator::Linear.from_now(@mem_apps.value, 0, @shutdown_seconds)
      end

      # Forces the VM off immediately, with no shutdown grace period.
      # @return [void]
      def force_off
        @shut_down_at = nil
        @started_at = nil
        @mem_apps = nil
      end

      # Hard power-cycle: {#force_off} then {#start}.
      # @return [void]
      def force_reboot
        force_off
        start
      end

      # Sets the guest-app memory usage to a fixed value (overriding the ramp).
      #
      # @param apps [Integer] app memory usage, in bytes
      # @raise [RuntimeError] if below {MIN_APP_MEMORY}, or if the VM is not running
      def memory_app=(apps)
        raise "mem for apps must be at least #{MIN_APP_MEMORY}" if apps < MIN_APP_MEMORY

        check_running
        @mem_apps = Interpolator::Const.new(apps.to_i)
      end

      # @raise [RuntimeError] if the VM is not running
      # @return [void]
      def check_running
        raise 'stopped' unless running?
      end

      # Sets the configured (`actual`) memory; increases apply instantly, decreases ramp
      # down over a few seconds to mimic a real guest.
      #
      # @param actual [Integer] new `actual` memory, in bytes; clamped between
      #   {MIN_ACTUAL} and the VM's {DomainInfo}'s `max_memory`
      # @raise [RuntimeError] if below {MIN_ACTUAL}, above `max_memory`, or the VM is not running
      def memory_actual=(actual)
        raise "Must be #{MIN_ACTUAL} or bigger" if actual < MIN_ACTUAL
        raise "Must be #{info.max_memory} at most" if actual > info.max_memory

        check_running
        actual = actual.to_i
        current = @actual.value
        @actual = if current <= actual
                    Interpolator::Const.new(actual)
                  else
                    Interpolator::Linear.from_now(current, actual, @decrease_active_seconds)
                  end
      end

      # Computes the VM's current {MemoryStat} from its simulated state.
      #
      # @return [MemoryStat, nil] the current memory stats, or `nil` if the VM is not running
      def to_mem_stat
        return nil unless running?

        actual = @actual.value.to_i
        available = actual - BIOS_KERNEL
        apps = @mem_apps.value.to_i.clamp(0, available)
        usable = available - apps
        disk_caches = @disk_caches.clamp(0, usable)
        rss = (apps + disk_caches).clamp(nil, available) + BIOS_KERNEL
        unused = usable - disk_caches
        # swap_in stays 0: nothing needs a simulated drain, and 0 is honest for a guest whose
        # swapped pages are never faulted back.
        MemoryStat.new(actual, unused, available, usable, disk_caches, 0, swap_out_total, rss,
                       DomainData.millis_now / 1000)
      end
    end
  end
end
