# frozen_string_literal: true

require_relative 'spec_helper'
require 'utils'

describe Run do
  context 'sync' do
    it 'runs command successfully' do
      assert_equal 'foo', Run.sync('echo foo').strip
    end
    it 'raises when command doesnt exist' do
      assert_raises(StandardError) { Run.sync('echjasd foo') }
      assert_raises(StandardError) { Run.sync('cat non-existing-file') }
    end
  end
  context 'async' do
    it 'runs command successfully' do
      out = Helpers.setup_dummy_logger
      Run.async('echo foo').join
      assert_equal '• debug   echo foo: exited successfully', out.string.strip
    end
    it 'raises when command doesnt exist' do
      Helpers.setup_dummy_logger
      assert_raises(StandardError) { Run.async('echjasd foo') }
    end
    it 'logs error when command fails' do
      out = Helpers.setup_dummy_logger
      Run.async('cat non-existing-file').join
      assert_equal '⨯ error   cat non-existing-file failed with 1: cat: non-existing-file: No such file or directory (os error 2)',
                   out.string.strip
    end
  end
end
