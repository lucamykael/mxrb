# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/artifacts'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Artifacts do
  it 'reports parse errors and warnings with one-based columns' do
    diagnostics = described_class.diagnostics("def m\n  unused = 1\nend\ndef broken(\n", file: 'a.rb')
    expect(diagnostics.map { _1[:severity] }.uniq).to contain_exactly('error', 'warning')
    warning = diagnostics.find { _1[:severity] == 'warning' }
    expect(warning).to include(file: 'a.rb', line: 2, column: 3, message: /unused/)
    expect(described_class.diagnostics("puts [1]\n", file: nil)).to eq([])
  end

  it 'lists declared artifacts qualified by their module folder without evaluating the file' do
    source = <<~RUBY
      entity :Order do
        string :Number
      end
      Mxrb.entity :Ignored
      page "Sales.Overview" do
        microflow 'Nested'
      end
      entity do
      end
      nanoflow dynamic_name
      helper :NotAnArtifact
    RUBY
    expect(described_class.declarations(source, path: 'modules/Sales/domain/entities/order.rb')).to eq(
      [{ kind: 'entity', name: 'Order', qualified_name: 'Sales.Order', line: 1 },
       { kind: 'page', name: 'Sales.Overview', qualified_name: 'Sales.Overview', line: 5 },
       { kind: 'microflow', name: 'Nested', qualified_name: 'Sales.Nested', line: 6 }]
    )
    expect(described_class.declarations('enumeration :Status', path: 'app/enums.rb'))
      .to eq([{ kind: 'enumeration', name: 'Status', qualified_name: 'Status', line: 1 }])
    expect(described_class.declarations('entity :Broken do', path: nil)).to eq([])
  end
end
# rubocop:enable Metrics
