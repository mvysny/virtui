# frozen_string_literal: true

require_relative 'spec_helper'
require 'virt/virtcache'
require 'virt/vm_emulator'
require 'app_layout'
require 'virt/ballooning'

describe AppLayout do
  let(:layout) do
    Helpers.setup_dummy_logger
    cache = VirtCache.new(VMEmulator.demo, PcEmulator.new)
    Screen.new
    AppLayout.new(cache, Ballooning.new(cache))
  end

  it 'smokes' do
    layout
  end
end
