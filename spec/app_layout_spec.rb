# frozen_string_literal: true

require_relative 'spec_helper'

module Tuile
  describe UI::AppLayout do
    before { Screen.fake }
    after { Screen.close }
    let(:layout) do
      Helpers.setup_dummy_logger
      cache = Virt::Cache.new(Virt::VMEmulator.demo, PcEmulator.new)
      UI::AppLayout.new(cache, Virt::Ballooning.new(cache))
    end

    it 'smokes' do
      layout
    end
  end
end
