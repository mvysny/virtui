# frozen_string_literal: true

# The libvirt backend: the domain model (VMs, their memory/disk/CPU stats) and
# the clients that talk to libvirt — {Virt::Virsh} (via the `virsh` CLI),
# {Virt::Cache} (thread-safe runtime cache) and {Virt::VMEmulator} (demo mode).
module Virt
end
