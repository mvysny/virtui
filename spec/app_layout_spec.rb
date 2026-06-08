# frozen_string_literal: true

require_relative 'spec_helper'

module Tuile
  describe AppLayout do
    before { Screen.fake }
    after { Screen.close }
    let(:layout) do
      Helpers.setup_dummy_logger
      cache = VirtCache.new(VMEmulator.demo, PcEmulator.new)
      AppLayout.new(cache, Ballooning.new(cache))
    end

    it 'smokes' do
      layout
    end
  end
end
