# frozen_string_literal: true

require_relative 'spec_helper'
require 'formatter'

describe Formatter do
  let(:f) do
    Rainbow.enabled = true # force-enable for CI
    Formatter.new
  end
end
