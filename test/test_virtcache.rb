# frozen_string_literal: true

require 'minitest/autorun'
require 'virtcache'
require 'vm_emulator'

class TestVirtCache < Minitest::Test
  def test_smoke
    VirtCache.new(VMEmulator.new)
  end
end
