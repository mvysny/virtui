# frozen_string_literal: true

require_relative 'spec_helper'

describe Run do
  context 'sync' do
    it 'runs command successfully' do
      assert_equal 'foo', Run.sync('echo foo').strip
    end
    it 'raises when command doesnt exist' do
      assert_raises(StandardError) { Run.sync('echjasd foo') }
      assert_raises(StandardError) { Run.sync('cat non-existing-file') }
    end
    # One argument per word means no shell, so nothing in an argument is ever reparsed.
    it 'passes arguments through without a shell' do
      assert_equal "it's", Run.sync('echo', "it's").strip
      assert_equal '*', Run.sync('echo', '*').strip
      assert_equal 'a b  c', Run.sync('echo', 'a b  c').strip
      assert_equal '$HOME `id`', Run.sync('echo', '$HOME `id`').strip
    end
    # Past the 64 KiB pipe buffer: reading only after the child exits would deadlock here.
    it 'returns output larger than a pipe buffer' do
      assert_equal 200_000, Run.sync('head', '-c', '200000', '/dev/zero').bytesize
      assert_equal 200_000, Run.sync('head', '-c', '200000', '/dev/zero', cancellation: Cancellation.new).bytesize
    end

    context 'with a cancellation' do
      it 'runs as without one until canceled' do
        assert_equal "foo\n", Run.sync('echo', 'foo', cancellation: Cancellation.new)
        assert_raises(RuntimeError) { Run.sync('cat', 'non-existing-file', cancellation: Cancellation.new) }
      end

      it 'stops and reaps the command on a cancel, and raises' do
        Dir.mktmpdir do |dir|
          pid_file = File.join(dir, 'pid')
          c = Cancellation.new
          canceler = Thread.new do
            Kernel.sleep(0.01) until File.size?(pid_file)
            c.cancel
          end
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          assert_raises(Cancellation::CanceledError) do
            Run.sync('sh', '-c', "echo $$ > #{pid_file}; exec sleep 10", cancellation: c)
          end
          took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          assert_operator took, :<, 5, 'waited the child out instead of stopping it'
          canceler.join
          pid = File.read(pid_file).to_i
          assert_raises(Errno::ESRCH, 'the child outlived the cancel') { Process.kill(0, pid) }
        end
      end

      it 'spawns nothing once canceled' do
        Dir.mktmpdir do |dir|
          marker = File.join(dir, 'ran')
          c = Cancellation.new
          c.cancel
          assert_raises(Cancellation::CanceledError) { Run.sync('touch', marker, cancellation: c) }
          refute File.exist?(marker)
        end
      end
    end
  end
  context 'async' do
    it 'runs command successfully' do
      out = Helpers.setup_dummy_logger
      Run.async('echo foo').join
      assert_equal "• debug   'echo foo': OK", out.string.strip
    end
    # Logged, not raised: the caller is often the UI thread, where a raise is a crash.
    it 'logs error when command doesnt exist' do
      out = Helpers.setup_dummy_logger
      Run.async('echjasd', 'foo').join
      assert out.string.include?('⨯ error   No such file or directory'), out.string
    end
    it 'logs error when command fails' do
      out = Helpers.setup_dummy_logger
      Run.async('cat non-existing-file').join
      expected = "⨯ error   Command 'cat non-existing-file' failed with 1: cat: non-existing-file: No such file or directory"
      assert out.string.strip.include?(expected), out.string.strip
    end
  end
end
