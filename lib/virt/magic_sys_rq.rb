# frozen_string_literal: true

module Virt
  # Ends a running Linux guest the way a stuck console would: Alt+SysRq S, U, then O or B,
  # typed into its emulated keyboard through `virsh send-key`. Softer than `virsh destroy` —
  # the guest's dirty pages reach the disk and its filesystems are left clean — and still
  # works when the guest's own shutdown hangs, where an ACPI shutdown waits forever:
  #
  #   MagicSysRq.refusal(cache.guest_os, cache.sysrq_mask)   # => nil when the guest allows it
  #   MagicSysRq.new(runner: VirshSpawn.new).power_off('vt-ubuntu')
  #
  # Nothing in the guest answers a key, so each step is given {STEP_SECONDS} and the result is
  # judged by the domain's state alone. See design/decisions.md D_sysrq_power_off.
  #
  # Never on the UI thread: a power-off takes {STEP_SECONDS} twice, then up to {OFF_SECONDS}.
  class MagicSysRq
    # The `kernel.sysrq` bits the S‑U‑O/B sequence needs: sync, remount read-only, and
    # reboot/power-off (`Documentation/admin-guide/sysrq.rst`).
    NEEDED_BITS = 16 | 32 | 128

    # Seconds between two keys. S and U are queued kernel work with no reply; 26 MB of dirty
    # pages were synced in under 0.5 s (design/research.md R_sysrq_send_key), and a sync that
    # never ends must not hold O back anyway.
    STEP_SECONDS = 3

    # Seconds O is given to turn the domain off; it took under 1 s on vt-ubuntu.
    OFF_SECONDS = 10

    # Why the sequence would do nothing to this guest.
    #
    #   MagicSysRq.refusal(GuestOS::UNKNOWN, nil)   # => "not a Linux guest"
    #   MagicSysRq.refusal(linux, 16)                # => "the guest's kernel.sysrq = 16 allows no remount or power-off"
    #
    # @param guest_os [GuestOS] what the domain declares
    # @param mask [Integer, nil] the guest's `kernel.sysrq`, or `nil` if it was never read
    # @return [String, nil] the reason, or `nil` if S, U and O/B all reach the guest's kernel
    def self.refusal(guest_os, mask)
      return 'not a Linux guest' unless guest_os.linux?
      return 'SysRq mask unknown: the guest agent has not answered' if mask.nil?
      # 1 enables every function; any other value is a bitmask.
      return nil if mask == 1 || mask & NEEDED_BITS == NEEDED_BITS

      "the guest's kernel.sysrq = #{mask} allows no remount or power-off"
    end

    # @param runner [VirshSpawn, VirshSession] transport; every call here spawns ({VirshSession#sync})
    # @param step_seconds [Integer, Float] see {STEP_SECONDS}; lowered by the specs
    # @param off_seconds [Integer, Float] see {OFF_SECONDS}; lowered by the specs
    def initialize(runner:, step_seconds: STEP_SECONDS, off_seconds: OFF_SECONDS)
      @runner = runner
      @step_seconds = step_seconds
      @off_seconds = off_seconds
    end

    # Syncs, remounts read-only and powers the guest off, then waits for the domain to stop.
    #
    # @param domain [String] a running Linux VM whose mask allows it (see {.refusal})
    # @return [void]
    # @raise [RuntimeError] if `virsh send-key` fails, or the domain still runs {OFF_SECONDS}
    #   after O — a mask changed since it was read, or a guest with no keyboard device
    def power_off(domain)
      sync_and_remount(domain)
      send_key(domain, 'KEY_O')
      deadline = Cooldown.of(@off_seconds)
      until @runner.sync('domstate', domain).strip == 'shut off'
        raise "#{domain} still runs #{@off_seconds}s after SysRq O; force it off if it must go" unless deadline.active?

        sleep @off_seconds / 20.0
      end
    end

    # Syncs, remounts read-only and reboots the guest. Unchecked: a rebooted domain stays
    # `running`, so its state cannot tell whether B arrived.
    #
    # @param domain [String] a running Linux VM whose mask allows it (see {.refusal})
    # @return [void]
    # @raise [RuntimeError] if `virsh send-key` fails
    def reboot(domain)
      sync_and_remount(domain)
      send_key(domain, 'KEY_B')
    end

    # @param domain [String]
    # @return [void]
    private def sync_and_remount(domain)
      send_key(domain, 'KEY_S')
      sleep @step_seconds
      send_key(domain, 'KEY_U')
      sleep @step_seconds
    end

    # @param domain [String]
    # @param key [String] the Linux keycode name after Alt+SysRq, e.g. `KEY_S`
    # @return [void]
    private def send_key(domain, key)
      @runner.sync('send-key', domain, 'KEY_LEFTALT', 'KEY_SYSRQ', key)
      $log.info "#{domain}: sent Alt+SysRq+#{key.delete_prefix('KEY_')}"
    end
  end
end
