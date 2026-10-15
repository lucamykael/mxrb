# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::Runtime::SystemMetamodel do
  def names(version) = described_class.for(version).fetch('objects').map { _1.fetch('name') }

  it 'reports the System module recorded from the newest Runtime not newer than the project' do
    expect(described_class.for('10.24.18.103793').fetch('mendix_version')).to eq('10.24.0')
    expect(described_class.for('11.12.3').fetch('mendix_version')).to eq('11.12.1')
    expect(described_class.for('9.24.0').fetch('mendix_version')).to eq('10.24.0')
    expect(described_class.for(nil).fetch('mendix_version')).to eq('10.24.0')
    expect(described_class.for('unversioned').fetch('mendix_version')).to eq('10.24.0')
    expect(names('11.12.1') - names('10.24.18')).to include('System.WorkflowSubProcess', 'System.WorkflowGroup')
    expect(described_class.for('11.12.1')).to be_frozen.and equal(described_class.for('11.12.1'))
  end

  it 'lists the values of each System enumeration of that Runtime' do
    states = ->(version) { described_class.enumerations(version).fetch('System.WorkflowState').map { _1.fetch('id') } }
    expect(states.call('11.12.1')).to include('InProgress', 'Completed')
    expect(described_class.enumerations('11.12.1')).to have_key('System.WorkflowSubProcessState')
    expect(described_class.enumerations('10.24.18')).not_to have_key('System.WorkflowSubProcessState')
  end
end
