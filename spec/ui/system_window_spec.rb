# frozen_string_literal: true

require_relative '../spec_helper'

# A System::Emulator whose CPU flags and disks can be varied, so SystemWindow's
# flag-dependent CPU summary and its per-disk render loop can be exercised (the base
# Emulator reports a fixed flag set and no disks).
class FakeSysInfo < System::Emulator
  def initialize(cpu_flags: %w[svm npt pdpe1gb], disks: {})
    super()
    @cpu_flags = cpu_flags.to_set
    @disks = disks
  end

  attr_reader :cpu_flags

  def disk_usage(_qcow2_files) = @disks
end

module Tuile
  describe UI::SystemWindow do
    before { Screen.fake }
    after { Screen.close }

    def window_for(cpu_flags: %w[svm npt pdpe1gb], disks: {})
      cache = Virt::Cache.new(Virt::VMEmulator.demo, FakeSysInfo.new(cpu_flags: cpu_flags, disks: disks))
      w = UI::SystemWindow.new(cache)
      Screen.instance.content = w
      w.rect = Rect.new(0, 0, 40, 20)
      w
    end

    # The lines of the currently-open help InfoWindow, joined into one string.
    def help_text
      info = Screen.instance.popups[0].content
      info.content.lines.join("\n")
    end

    it 'smokes' do
      window_for
    end

    context('CPU summary') do
      it 'lists AMD virtualization flags' do
        summary = window_for(cpu_flags: %w[svm npt pdpe1gb]).send(:format_cpu_info)
        %w[svm npt pdpe1gb].each { |f| assert summary.include?(f), summary }
      end

      it 'lists the Intel flags, folding any xsave* into "xsave"' do
        flags = %w[vmx ept tsc_deadline pcid vpid invpcid pdpe1gb xsaveopt]
        summary = window_for(cpu_flags: flags).send(:format_cpu_info)
        %w[vmx ept tsc_deadline pcid vpid invpcid pdpe1gb xsave].each { |f| assert summary.include?(f), summary }
      end

      it 'reports software emulation when no virtualization flag is present' do
        summary = window_for(cpu_flags: []).send(:format_cpu_info)
        assert summary.include?('software'), summary
        refute summary.include?('vmx'), summary
      end
    end

    context('help window') do
      it 'opens on h and explains the present flags' do
        w = window_for(cpu_flags: %w[vmx ept tsc_deadline pcid vpid invpcid pdpe1gb xsaveopt])
        w.handle_key('h')
        popups = Screen.instance.popups
        assert_equal 1, popups.length
        assert_equal Component::InfoWindow, popups[0].content.class
        %w[vmx ept tsc_deadline pcid vpid invpcid pdpe1gb xsave].each { |f| assert help_text.include?(f), help_text }
      end

      it 'explains AMD flags' do
        window_for(cpu_flags: %w[svm npt]).handle_key('h')
        assert help_text.include?('svm'), help_text
        assert help_text.include?('npt'), help_text
      end

      it 'explains software emulation when no virtualization flag is present' do
        window_for(cpu_flags: []).handle_key('h')
        assert help_text.include?('software'), help_text
      end
    end

    context('key handling') do
      it 'keyboard_hint advertises the Help key' do
        assert window_for.keyboard_hint.include?('Help')
      end

      it 'returns false for an unhandled key' do
        refute window_for.handle_key('z')
      end
    end

    it 'renders a row per disk' do
      disks = { 'sda' => System::DiskUsage.new(ResourceUsage.new(100.GiB, 40.GiB), 12.GiB, ['/x.qcow2']) }
      lines = window_for(disks: disks).content.lines.map(&:to_s)
      assert(lines.any? { |l| l.include?('sda') }, lines.join("\n"))
    end
  end
end
