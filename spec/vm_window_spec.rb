# frozen_string_literal: true

require_relative 'spec_helper'
require 'virt/virtcache'
require 'virt/vm_emulator'
require 'vm_window'
require 'timecop'

describe VMWindow do
  let(:now) { Time.now }
  let(:window) do
    cache = Timecop.freeze(now) { VirtCache.new(VMEmulator.demo, PcEmulator.new) }
    w = Timecop.freeze(now + 5) do
      cache.update
      VMWindow.new(cache, Ballooning.new(cache))
    end
    w.active = true
    w.show_disk_stat = true
    w
  end

  it 'has the right content' do
    content = window.content.map { Rainbow.uncolor(it) }
    assert_equal '⏹ BASE', content[0]
    assert_equal '    vda: 50%   64G   128G | ', content[1]
    assert_equal '⏹ Fedora', content[2]
    assert_equal '    vda: 50%   64G   128G | ', content[3]
    assert_equal '▶ Ubuntu 🎈', content[4]
    assert_equal '    CPU:  0%          1 t |   0%          8 t', content[5]
    assert_equal '    RAM: 25%    2G   7.9G |   9%  3.1G    32G', content[6]
    assert_equal '    vda: 50%   64G   128G | ', content[7]
    assert_equal '▶ win11 🎈', content[8]
    assert_equal '    CPU:  0%          1 t |   0%          8 t', content[9]
    assert_equal '    RAM: 25%    2G   7.9G |   9%  3.1G    32G', content[10]
    assert_equal '    vda: 50%   64G   128G | ', content[11]
  end

  context('cursor movement') do
    it 'moves cursor down correctly' do
      assert_equal 0, window.cursor.position
      # first VM is stopped and takes 2 lines
      window.handle_key("\e[B")
      assert_equal 2, window.cursor.position
      # second VM is running and takes 3 lines
      window.handle_key("\e[B")
      assert_equal 4, window.cursor.position
      # third VM is running and takes 3 lines
      window.handle_key("\e[B")
      assert_equal 8, window.cursor.position
      # no more VMs
      window.handle_key("\e[B")
      assert_equal 8, window.cursor.position
    end
    it 'moves cursor up correctly' do
      window.cursor.position = 8
      assert_equal 8, window.cursor.position
      window.handle_key("\e[A")
      assert_equal 4, window.cursor.position
      window.handle_key("\e[A")
      assert_equal 2, window.cursor.position
      window.handle_key("\e[A")
      assert_equal 0, window.cursor.position
      window.handle_key("\e[A")
      assert_equal 0, window.cursor.position
    end
  end
end
