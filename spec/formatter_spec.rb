# frozen_string_literal: true

require_relative 'spec_helper'
require 'formatter'

describe Formatter do
  let(:f) do
    Rainbow.enabled = true # force-enable for CI
    Formatter.new
  end
  it 'formats domain stat' do
    assert_equal "\e[32m▶\e[0m", f.format_domain_state(:running)
  end
end
