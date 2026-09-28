# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/presentation_documents_gate', __dir__)

RSpec.describe MxrbPresentationDocumentsGate do
  it 'certifies readable reusable documents through two identity-stable cycles' do
    Dir.mktmpdir('mxrb-presentation-documents-gate-spec-') do |workspace|
      report = described_class.run(['--workspace', workspace])

      expect(report).to include(
        passed: true, mendix_version: '11.12.1', cycles: 2,
        structural_validation: true, stable_native_ids: true,
        stable_documents: true, readable_typed_ruby: true, oracle: nil
      )
      expect(report.fetch(:documents)).to eq(
        'Forms$Layout' => 2, 'Forms$PageTemplate' => 1,
        'Forms$BuildingBlock' => 1, 'Forms$Snippet' => 1
      )
      expect(File).to exist(report.fetch(:final_mpr))
    end
  end
end
