# frozen_string_literal: true

# Host operating-system metrics: {System::Info} reads the host's CPU, memory and
# disk usage (via `/proc` and `df`), producing the {System::CpuStat},
# {System::CpuUsage}, {System::MemoryStat} and {System::DiskUsage} value objects.
# {System::Emulator} is an {System::Info}-compatible test double.
#
# The generic byte-usage value object {MemoryUsage} stays top-level — it is shared
# with the {Virt} guest backend.
module System
end
