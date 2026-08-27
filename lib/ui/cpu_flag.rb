# frozen_string_literal: true

module UI
  # One entry of the virtualization CPU-flag glossary: a `/proc/cpuinfo` token, how to
  # detect it, and what having it buys a KVM guest.
  #
  # {ALL} is the whole glossary and the single source of truth for both readers —
  # {SystemWindow}'s one-line CPU summary renders the {#name}s, {CpuFlagsWindow}
  # renders the {#description}s — so the two can no longer drift apart (they had:
  # the summary and the help each carried their own copy of the flag list).
  #
  # Names are the tokens as the kernel spells them in `/proc/cpuinfo`, so that what
  # the summary line shows is greppable there; that is why it says
  # `tsc_deadline_timer` and not the shorter `tsc_deadline`, which is not a flag.
  class CpuFlag < Data.define(:name, :description, :matcher)
    # @param name [String] the flag as `/proc/cpuinfo` spells it, and as the CPU
    #   summary line shows it
    # @param description [String] what the flag buys a guest, in prose — word-wrapped
    #   by {CpuFlagsWindow}, so it may be a sentence or three
    # @param matcher [Proc, nil] `(Set<String>) -> Boolean` deciding whether the host
    #   has this flag; defaults to a plain membership test on {#name}
    def initialize(name:, description:, matcher: nil)
      super(name: name, description: description,
            matcher: matcher || ->(flags) { flags.include?(name) })
    end

    # @param flags [Set<String>] the host's CPU flags, from {System::Info#cpu_flags}
    # @return [Boolean] whether this host has this flag
    def present_in?(flags) = matcher.call(flags)

    # The glossary, in the order both readers render it: the virtualization extension
    # itself first, then memory virtualization, then the timing/TLB/state-switch
    # features that make a guest cheaper to run.
    # @return [Array<CpuFlag>]
    ALL = [
      new(name: 'vmx',
          description: 'Intel VT-x, the hardware extension KVM needs to run guest code natively on this ' \
                       'host. Without it (or svm) QEMU has to interpret the guest instruction by ' \
                       'instruction, which is slower by an order of magnitude.'),
      new(name: 'svm',
          description: "AMD-V (Secure Virtual Machine), AMD's hardware virtualization extension and the " \
                       'counterpart of Intel\'s vmx: what KVM needs to run guest code natively on this host.'),
      new(name: 'software',
          matcher: ->(flags) { !flags.include?('vmx') && !flags.include?('svm') },
          description: 'This CPU offers neither vmx nor svm, so QEMU must emulate the guest CPU instruction ' \
                       'by instruction — correct, but very slow. Usually the extension is merely switched ' \
                       'off: look for "Intel VT-x" / "SVM Mode" in the BIOS/UEFI setup. If this host is ' \
                       'itself a VM, its own host has to pass virtualization through (nested virtualization).'),
      new(name: 'ept',
          description: "Extended Page Tables, Intel's second-level address translation: the MMU walks the " \
                       "guest's own page tables in hardware, so KVM no longer has to maintain shadow page " \
                       'tables and trap every guest page-table write. Reported by the kernel on the ' \
                       '"vmx flags" line rather than among the general CPU flags.'),
      new(name: 'npt',
          description: "Nested Page Tables (AMD's name for second-level address translation, also marketed " \
                       "as Rapid Virtualization Indexing) — the counterpart of Intel's ept: the guest's page " \
                       'tables are walked by the MMU instead of being shadowed by KVM.'),
      new(name: 'tsc_deadline_timer',
          description: 'The local APIC timer can be armed with an absolute TSC value instead of a ' \
                       'counting-down divisor, so a one-shot timer costs the guest a single MSR write. ' \
                       'Cheaper and more precise timekeeping inside the guest.'),
      new(name: 'pcid',
          description: 'Process-Context Identifiers tag TLB entries with the address space they belong to, ' \
                       'so switching processes stops flushing the whole TLB. It earns its keep especially ' \
                       'since Meltdown mitigation (KPTI), which swaps page tables on every syscall.'),
      new(name: 'vpid',
          description: 'Virtual Processor IDs (Intel) tag TLB entries with the VM they belong to, so ' \
                       'entering and leaving a guest no longer flushes the TLB. What pcid does for process ' \
                       'switches, vpid does for guest/host switches. Also reported on the "vmx flags" line.'),
      new(name: 'invpcid',
          description: 'The INVPCID instruction invalidates the TLB entries of one address space — or one ' \
                       'page within it — instead of flushing wholesale. The fine-grained flush that makes ' \
                       'pcid pay off.'),
      new(name: 'pdpe1gb',
          description: "The MMU can map 1 GiB pages. Backing a guest's RAM with 1 GiB hugepages shrinks its " \
                       'page tables dramatically and shortens every nested page walk, which is the hottest ' \
                       'path in a memory-heavy VM.'),
      new(name: 'xsave',
          matcher: ->(flags) { flags.any? { |it| it.start_with?('xsave') } },
          description: 'The XSAVE family saves and restores the extended register state (SSE, AVX, ' \
                       'AVX-512 and friends) with one instruction; the xsaveopt/xsavec/xsaves variants ' \
                       'skip the components that did not change. KVM uses it to swap FPU state between ' \
                       'host and guest on every vCPU switch.')
    ].freeze

    # The glossary entries this host qualifies for, in {ALL} order.
    #
    # @param flags [Set<String>] the host's CPU flags, from {System::Info#cpu_flags}
    # @return [Array<CpuFlag>] never empty - a host with neither vmx nor svm matches
    #   the `software` entry
    def self.present_in(flags) = ALL.select { |it| it.present_in?(flags) }
  end
end
