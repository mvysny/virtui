# frozen_string_literal: true

require_relative 'spec_helper'
require 'virt/virtcache'
require 'virt/vm_emulator'
require 'app_screen'
require 'virt/ballooning'

describe AppScreen do
  let(:screen) do
    Helpers.setup_dummy_logger
    cache = VirtCache.new(VMEmulator.demo, PcEmulator.new)
    AppScreen.new(cache, Ballooning.new(cache))
  end

  it 'smokes' do
    screen
  end
end
