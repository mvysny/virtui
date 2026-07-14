# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::DomainInfo do
  it 'to_s' do
    assert_equal 'web: CPUs: 4, RAM: 8G', Virt::DomainInfo.new('web', 4, 8.GiB).to_s
  end
end
