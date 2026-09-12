# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/forms_core_storage_gate', __dir__)

RSpec.describe MxrbFormsCoreStorageGate do # rubocop:disable Metrics/BlockLength
  it 'materializes every concrete core widget under its Mendix 11 physical type' do
    Dir.mktmpdir('mxrb-forms-core-storage-spec-') do |workspace|
      report = described_class.run(['--workspace', workspace])
      expected = Mxrb::Forms::Catalog.for('11.12.1').concrete_widgets.map do |type|
        "Forms$#{Mxrb::Forms::StorageNaming.storage_type_name(type.name)}"
      end

      expect(report).to include(
        passed: true, mendix_version: '11.12.1', widget_count: 41,
        structural_validation: true, oracle: nil
      )
      expect(forms_types(report.fetch(:mpr))).to include(*expected)
    end
  end

  def forms_types(path)
    Mxrb.open(path) do |project|
      project.all_units.flat_map do |unit|
        collect_types(project.parse_bson(unit))
      end.uniq
    end
  end

  def collect_types(value)
    case value
    when Hash
      [value['$Type'], *value.values.flat_map { collect_types(_1) }].compact
    when Array
      value.reject { _1.is_a?(Integer) }.flat_map { collect_types(_1) }
    else
      []
    end
  end
end
