# frozen_string_literal: true

require_relative '../spec_helper'

# Records every `send-key`, and answers `domstate` with the states it is given, the last one
# from then on.
class SysRqRunner
  attr_reader :keys

  # @param states [Array<String>] what successive `domstate` calls print
  def initialize(*states)
    @states = states
    @keys = []
  end

  def sync(*args)
    case args
    in ['send-key', 'vt-ubuntu', 'KEY_LEFTALT', 'KEY_SYSRQ', key]
      @keys << key
      ''
    in ['domstate', 'vt-ubuntu']
      "#{@states.size > 1 ? @states.shift : @states.first}\n"
    end
  end
end

describe Virt::MagicSysRq do
  before { @log = Helpers.setup_dummy_logger }

  let(:linux) { Virt::VMEmulator::LINUX }

  # @return [Virt::MagicSysRq] one that waits a few milliseconds where the real one waits seconds
  def sysrq(runner) = described_class.new(runner: runner, step_seconds: 0.01, off_seconds: 0.2)

  context 'refusal' do
    it "allows Ubuntu's mask, and 1 for everything" do
      assert_nil described_class.refusal(linux, 176)
      assert_nil described_class.refusal(linux, 1)
      assert_nil described_class.refusal(linux, 0x01b6)
    end

    it 'refuses a mask that lacks remount or power-off' do
      assert_equal "the guest's kernel.sysrq = 16 allows no remount or power-off", described_class.refusal(linux, 16)
      refute_nil described_class.refusal(linux, 0)
      refute_nil described_class.refusal(linux, 16 | 128)
    end

    it 'refuses a non-Linux guest before an unread mask' do
      assert_equal 'not a Linux guest', described_class.refusal(Virt::VMEmulator::WINDOWS, nil)
      assert_equal 'not a Linux guest', described_class.refusal(Virt::GuestOS::UNKNOWN, 176)
      assert_includes described_class.refusal(linux, nil), 'SysRq mask unknown'
    end
  end

  it 'powers off with S, U, O and waits for the domain to stop' do
    runner = SysRqRunner.new('running', 'in shutdown', 'shut off')
    sysrq(runner).power_off('vt-ubuntu')
    assert_equal %w[KEY_S KEY_U KEY_O], runner.keys
    assert_includes @log.string, 'vt-ubuntu: sent Alt+SysRq+O'
  end

  it 'raises when the domain still runs after O' do
    runner = SysRqRunner.new('running')
    error = assert_raises(RuntimeError) { sysrq(runner).power_off('vt-ubuntu') }
    assert_includes error.message, 'vt-ubuntu still runs'
    assert_equal %w[KEY_S KEY_U KEY_O], runner.keys
  end

  it 'reboots with S, U, B' do
    runner = SysRqRunner.new('running')
    sysrq(runner).reboot('vt-ubuntu')
    assert_equal %w[KEY_S KEY_U KEY_B], runner.keys
  end
end
