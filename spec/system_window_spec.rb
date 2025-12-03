# frozen_string_literal: true

require_relative 'spec_helper'
require 'system_window'
require 'virt/vm_emulator'
require 'virt/virtcache'

describe SystemWindow do
  let(:cache) { VirtCache.new(VMEmulator.demo, PcEmulator.new) }
  before { Screen.fake }
  it 'smokes' do
    SystemWindow.new(cache)
  end
end
