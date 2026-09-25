# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'remaining defensive edge contracts' do # rubocop:disable Metrics/BlockLength
  it 'reports scalar AutoNumber defaults instead of assuming a stored-value document' do
    validator = Mxrb::Integrity::Validator.allocate
    validator.instance_variable_set(:@errors, [])
    attribute = {
      '$Type' => 'DomainModels$Attribute', 'Name' => 'Number',
      'NewType' => { '$Type' => 'DomainModels$AutoNumberAttributeType' }, 'Value' => 0
    }

    validator.send(:validate_attribute_default, { 'UnitID' => 'unit' }, attribute)
    expect(validator.instance_variable_get(:@errors).join).to include('default value of 1 or higher')
  end

  it 'allows the exact downgrade audit target when the read-only loss report is empty' do
    mpr = double('mpr', architecture_definition: { modules: [] }, readonly?: false)
    project = Mxrb::Model::Project.new(mpr)
    allow(project).to receive(:mendix_version).and_return('11.12.1')
    allow(project).to receive(:migration_losses).with('9.6.1.29396').and_return([])
    allow(project).to receive(:rewrite_for_version!).with('9.6.1.29396', include(version: '9.6.1.29396'))
    allow(project).to receive(:refresh!).and_return(project)

    expect(project.migrate_to!('9.6.1.29396')).to equal(project)
  end

  it 'treats a module without a private manifest match as newly authored security' do
    manifest = Mxrb::RubyApp::Manifest.new('/tmp/new-security', 'mode' => 'ruby', 'modules' => [])
    definition = { module_name: 'NewModule', id: '', roles: [] }

    expect(Mxrb::RubyApp::SecurityIdentity.new(manifest).module_security(definition)).to eq(definition)
  end

  it 'distinguishes a missing pluggable baseline handle from a missing baseline file' do
    without_manifest = Mxrb::RubyApp::PluggableContext.new
    without_manifest.with_page('page') do
      expect { without_manifest.for_widget('widget', widget_id: 'vendor.Widget') }
        .to raise_error(Mxrb::ValidationError, /require their private runtime baseline/)
    end

    manifest = double('manifest', absolute_path: '/definitely/missing/private.mpr')
    missing_file = Mxrb::RubyApp::PluggableContext.new(manifest:)
    missing_file.with_page('page') do
      expect { missing_file.for_widget('widget', widget_id: 'vendor.Widget') }
        .to raise_error(Mxrb::ValidationError, /baseline is unavailable/)
    end
  end

  it 'validates loss-audit input, cycles, paths, and every diagnostic value category' do
    expect { Mxrb::StudioCompatibility::LossAudit.new(target_version: '11.12.1') }
      .to raise_error(ArgumentError, /exact Mendix 9/)
    audit = Mxrb::StudioCompatibility::LossAudit.new(target_version: '9.6.1.29396')
    expect { audit.audit([], unit_id: 'unit') }.to raise_error(ArgumentError, /document Hash/)
    expect { audit.audit({}, unit_id: :unit) }.to raise_error(ArgumentError, /String unit/)
    cyclic = { '$Type' => 'Unknown' }
    cyclic['Self'] = cyclic
    expect { audit.audit(cyclic, unit_id: 'unit') }.to raise_error(ArgumentError, /acyclic/)

    values = [nil, true, 'text', 1, 1.5, {}, [], Object.new]
    findings = values.flat_map.with_index do |value, index|
      audit.audit(
        { '$Type' => 'Forms$PageParameter', 'DefaultValue' => value,
          'UnknownPrivateKey' => [{ '$Type' => 'Forms$PageVariable', 'SubKey' => value }] },
        unit_id: "unit-#{index}"
      )
    end
    expect(findings.map(&:value_type).uniq)
      .to contain_exactly(:null, :boolean, :string, :integer, :float, :object, :collection, :other)
    expect(findings.map(&:path)).to include('$.DefaultValue', '$[field:2][0].SubKey')

    settings = {
      '$Type' => 'Settings$ProjectSettings',
      'Settings' => [2, { '$Type' => 'Settings$JarDeploymentSettings' }, 'opaque']
    }
    expect(audit.audit(settings, unit_id: 'settings').map(&:classification))
      .to include(:removed_setting_part)
  end

  it 'handles absent templates and marker-free collections in compatibility reconciliation' do
    Dir.mktmpdir('mxrb-no-templates-') do |directory|
      compatibility = Mxrb::StudioCompatibility.new('11.12.1', template_root: directory)
      conversion = { '$Type' => 'Projects$ProjectConversion', 'OneTimeConversions' => nil }
      texts = { '$Type' => 'Texts$SystemTextCollection', 'SystemTexts' => nil }
      expect(compatibility.apply_document!(conversion)).to equal(conversion)
      expect(compatibility.apply_document!(texts)).to equal(texts)
    end

    compatibility = Mxrb::StudioCompatibility.new('future')
    expect(compatibility.apply_document!({ '$Type' => 'Unknown' })).to eq('$Type' => 'Unknown')
    expect(compatibility.send(:items, nil)).to eq([])
    expect(compatibility.send(:array_marker, nil)).to be_nil
    source = { 'OneTimeConversions' => [{ 'Name' => 'Keep' }] }
    target = { 'OneTimeConversions' => [{ 'Name' => 'Keep' }, { 'Name' => 'Add' }] }
    expect(compatibility.send(:reconciled_conversions, source, target).map { _1['Name'] })
      .to eq(%w[Keep Add])
    source = { 'SystemTexts' => [{ 'InternalKey' => 'keep' }] }
    target = { 'SystemTexts' => [{ 'InternalKey' => 'keep' }, { 'InternalKey' => 'add' }] }
    expect(compatibility.send(:reconciled_system_texts, source, target).map { _1['InternalKey'] })
      .to eq(%w[keep add])
  end

  it 'covers compatibility helpers for malformed collections and pre-existing target fields' do
    old = Mxrb::StudioCompatibility::Mendix10240073019Strategy.new
    expect(old.send(:items, nil)).to eq([])
    expect(old.send(:items, [{ '$Type' => 'Item' }]).size).to eq(1)

    nine = Mxrb::StudioCompatibility::Mendix96129396Strategy.new
    settings = { '$Type' => 'Settings$ProjectSettings', 'Settings' => nil }
    expect(nine.apply_document!(settings)).to equal(settings)

    eleven = Mxrb::StudioCompatibility::Mendix11121Strategy.new
    entity = { '$Type' => 'DomainModels$EntityImpl', 'EventHandlers' => [{ '$Type' => 'Handler' }] }
    eleven.apply_document!(entity)
    expect(entity).to have_key('EventHandlers')
    tracing = {
      '$Type' => 'Settings$TracingConfiguration', 'Endpoint' => nil,
      'Existing' => 'source', 'Replacement' => 'target'
    }
    eleven.send(:rename_fields!, tracing, 'Existing' => 'Replacement')
    eleven.apply_document!(tracing)
    expect(tracing).to include('Replacement' => 'target', 'Endpoint' => nil)
    settings = { '$Type' => 'Settings$ProjectSettings', 'Settings' => nil }
    eleven.apply_document!(settings)
    expect(settings['Settings']).to be_nil
    expect(eleven.send(:items, [{ '$Type' => 'Item' }]).size).to eq(1)
  end
end
