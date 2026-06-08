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
        MemoryStat.new(actual, unused, available, usable, disk_caches, rss, DomainData.millis_now / 1000)
      end
    end
  end
end
