# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/coverage'

RSpec.describe Mxrb::Forms::CoverageLedger do # rubocop:disable Metrics/BlockLength
  subject(:ledger) { described_class.for_node }

  it 'uses every concrete inherited property occurrence as the denominator' do
    report = ledger.report

    expect(report.version).to eq('11.12.1')
    expect(report.widget_count).to eq(41)
    expect(report.property_count).to eq(455)
    expect(report.count(:represented)).to eq(455)
    expect(report.count(:imported)).to be_zero
    expect(report.entries).to all(be_a(Mxrb::Forms::CoverageEntry))
    expect(report.entries).not_to include(a_kind_of(Hash))
  end

  it 'does not mistake representation or native preservation for bidirectional completion' do
    report = ledger.report

    expect(report).not_to be_complete
    expect { report.assert_complete! }
      .to raise_error(
        Mxrb::Forms::IncompleteCoverageError,
        %r{represented=455/455, source_emitted=0/455, storage_transcoded=0/455, imported=0/455}
      )
  end

  it 'tracks clean Ruby emission separately from import and native compilation' do
    report = described_class.for_source_emitter.report

    expect(report.count(:represented)).to eq(455)
    expect(report.count(:source_emitted)).to eq(455)
    expect(report.count(:imported)).to be_zero
    expect(report.count(:compiled)).to be_zero
    expect(report).not_to be_complete
  end

  it 'tracks schema storage transcoding without claiming project or Studio validation' do
    report = described_class.for_mpr_codec.report

    expect(report.count(:storage_transcoded)).to eq(455)
    expect(report.count(:imported)).to be_zero
    expect(report.count(:compiled)).to be_zero
    expect(report.count(:studio_validated)).to be_zero
  end

  it 'records exhaustive synthetic round-trips without inflating real import or Studio evidence' do
    report = described_class.for_synthetic_round_trip.report

    expect(report.count(:represented)).to eq(455)
    expect(report.count(:source_emitted)).to eq(455)
    expect(report.count(:storage_transcoded)).to eq(455)
    expect(report.count(:round_tripped)).to eq(455)
    expect(report.count(:imported)).to be_zero
    expect(report.count(:compiled)).to be_zero
    expect(report.count(:studio_validated)).to be_zero
    expect(report).not_to be_complete
  end

  it 'requires a concrete schema property, a known phase, and evidence for every claim' do
    expect { ledger.claim(:widget, :name, :imported, evidence: 'test') }
      .to raise_error(ArgumentError, /not a concrete widget/)
    expect { ledger.claim(:action_button, :missing, :imported, evidence: 'test') }
      .to raise_error(KeyError)
    expect { ledger.claim(:action_button, :name, :preserved, evidence: 'test') }
      .to raise_error(ArgumentError, /unknown coverage phase/)
    expect { ledger.claim(:action_button, :name, :imported, evidence: '') }
      .to raise_error(ArgumentError, /evidence/)
  end

  it 'accumulates independent evidence without duplicate phase inflation' do
    ledger.claim(:action_button, :name, :imported, evidence: 'reader spec')
    ledger.claim(:action_button, :name, :imported, :compiled, evidence: 'writer spec')
    entry = ledger.report.entries.find do |candidate|
      candidate.widget.name == 'ActionButton' && candidate.property.name == 'name'
    end

    expect(entry.phases).to contain_exactly(:represented, :imported, :compiled)
    expect(entry.evidence).to include('Mxrb::Forms::Node', 'reader spec', 'writer spec')
  end
end
