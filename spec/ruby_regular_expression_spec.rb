# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::RegularExpression do
  after { Mxrb::RubyApp::Registry.reset! }

  def fixture(path, referenced: false)
    define_native_fixture(path)
    mpr = Mxrb::IO::MprFile.open(path)
    decorate_regular_expression(mpr)
    add_validation_reference(mpr, path) if referenced
  ensure
    mpr&.close
  end

  def define_native_fixture(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        entity(:Item) { string :Name }
        regular_expression :Pattern, expression: '[A-Z]+'
        regular_expression :Unused, expression: 'unused'
      end
      self.module(:Other) { regular_expression :Foreign, expression: 'foreign' }
    end
  end

  def decorate_regular_expression(mpr)
    unit = mpr.all_units.find do |raw|
      document = mpr.parse_contents(raw)
      document['$Type'] == described_class::TYPE && document['Name'] == 'Pattern'
    end
    document = mpr.parse_contents(unit).merge('VendorField' => { 'enabled' => false, 'optional' => nil },
                                              'Documentation' => nil, 'Excluded' => false)
    document.delete('ExportLevel')
    mpr.update_unit(unit.fetch('UnitID'), document)
  end

  def add_validation_reference(mpr, path)
    Mxrb::Writer.new(path, version: '11.12.1', modules: [])
                .synchronize_ruby_entity_behaviors!(mpr, module_name: 'App', entities: [{
                  name: 'Item', validation_rules: [{ attribute: 'Name', kind: 'DomainModels$RegExRuleInfo',
                                                     rule_info: { 'RegExIdentifier' => 'App.Pattern' } }]
                }])
  end

  def expressions(path)
    Mxrb.open(path) do |project|
      project.modules.flat_map do |mod|
        mod.domain_documents.filter_map do |entry|
          ["#{mod.name}.#{entry[:name]}", entry] if entry[:type] == described_class::TYPE
        end
      end.to_h
    end
  end

  def native_snapshot(path)
    Mxrb.open(path) do |project|
      project.query('SELECT UnitID, ContainerID, ContainmentName, ContentsHash FROM Unit ORDER BY UnitID')
    end
  end

  def manifest_entries(root)
    Mxrb::RubyApp::Manifest.load(root).modules.flat_map { _1.fetch('regular_expressions') }
  end

  def source_path(root, name = 'pattern')
    File.join(root, 'app', 'regular_expressions', 'app', "#{name}.rb")
  end

  it 'keeps typed values immutable and distinguishes false, nil and absence' do
    implementation = Class.new(described_class)
    input = +'[A-Z]+'
    implementation.expression(input)
    implementation.excluded(false)
    implementation.documentation(nil)
    input.replace('changed')
    properties = implementation.native_definition.fetch(:properties)
    expect(properties).to eq('Expression' => '[A-Z]+', 'Excluded' => false, 'Documentation' => nil)
    expect(properties).to be_frozen
    expect(implementation.expression).to be_frozen
    expect { implementation.expression(/ruby/) }.to raise_error(TypeError)
    expect { implementation.excluded('false') }.to raise_error(TypeError)
    %w[A.B.C Unqualified A. .B].each do |name|
      expect { implementation.mendix_name(name) }.to raise_error(ArgumentError, /Module.Name/)
    end
    expect(Mxrb::RubyApp::Registry.all(:regular_expression)).to be_empty
  end

  it 'round-trips identities, unknown fields and optional values while applying Ruby edits' do
    Dir.mktmpdir('mxrb-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      fixture(original)
      before = expressions(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      portability = Mxrb::RubyApp::PortabilityReport.new(output)
      projected = portability.entries.select { _1.kind == 'regular_expression' }
      expect(projected.map(&:name)).to contain_exactly('App.Pattern', 'App.Unused', 'Other.Foreign')
      expect(projected.map(&:status).uniq).to eq(['native'])
      source = File.read(source_path(output))
      expect(source).to include('class Pattern < Mxrb::RubyApp::RegularExpression', 'excluded false',
                                'documentation nil')
      expect(source).not_to include('VendorField', 'export_level', 'id:', 'native_document', 'deep_structure')
      expect(source).not_to match(Mxrb::PublicSourceAudit::UUID)
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(expressions(rebuilt)).to eq(before)

      File.write(source_path(output), source.sub('[A-Z]+', '[0-9]+').sub('excluded false', 'excluded nil'))
      Mxrb::RubyApp.compile(output, rebuilt)
      expected = Marshal.load(Marshal.dump(before))
      expected['App.Pattern'][:doc]['Expression'] = '[0-9]+'
      expected['App.Pattern'][:doc]['Excluded'] = nil
      expect(expressions(rebuilt)).to eq(expected)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      expect(File.read(source_path(restored))).to include('excluded nil')
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Final.mpr'))
      expect(expressions(File.join(directory, 'Final.mpr'))).to eq(expected)
    end
  end

  it 'captures new private identities and custom source classes across re-export' do
    Dir.mktmpdir('mxrb-new-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      fixture(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      File.write(source_path(output, 'custom'), <<~RUBY)
        module App
          class Custom < Mxrb::RubyApp::RegularExpression
            mendix_name "App.NewPattern"
            expression "new"
          end
        end
      RUBY
      Mxrb::RubyApp.compile(output, rebuilt)
      identifier = expressions(rebuilt).fetch('App.NewPattern').fetch(:id)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      entry = manifest_entries(restored).find { _1['name'] == 'App.NewPattern' }
      expect(entry).to include('id' => identifier, 'ruby_class' => 'App::Custom',
                               'path' => 'app/regular_expressions/app/custom.rb')
      expect(File.read(source_path(restored, 'custom'))).not_to match(Mxrb::PublicSourceAudit::UUID)
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Final.mpr'))
      expect(expressions(File.join(directory, 'Final.mpr')).fetch('App.NewPattern')[:id]).to eq(identifier)
    end
  end

  it 'removes only an unreferenced declaration included in the private manifest' do
    Dir.mktmpdir('mxrb-remove-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      fixture(original)
      before = expressions(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      File.delete(source_path(output, 'unused'))
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(expressions(rebuilt)).to eq(before.reject { |name, _entry| name == 'App.Unused' })
    end
  end

  it 'does not prune native expressions outside the manifest-owned collection' do
    Dir.mktmpdir('mxrb-unmanaged-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      fixture(original)
      before = expressions(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      manifest_path = File.join(output, Mxrb::RubyApp::MANIFEST_PATH)
      manifest = JSON.parse(File.read(manifest_path))
      manifest.fetch('modules').each { _1['regular_expressions'] = [] }
      File.write(manifest_path, JSON.generate(manifest))
      Dir.glob(File.join(output, 'app', 'regular_expressions', '**', '*.rb')).each { File.delete(_1) }
      Mxrb::RubyApp.compile(output, rebuilt)
      # No authority means no restoration or pruning. The unrelated low-level
      # default remains outside this API; every native unit is retained.
      expect(expressions(rebuilt).transform_values { _1.fetch(:id) })
        .to eq(before.transform_values { _1.fetch(:id) })
      expect(expressions(rebuilt).fetch('App.Pattern')[:doc]['VendorField'])
        .to eq(before.fetch('App.Pattern')[:doc]['VendorField'])
    end
  end

  it 'renames an unreferenced document explicitly without changing its private identity or source path' do
    Dir.mktmpdir('mxrb-rename-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      fixture(original)
      identifier = expressions(original).fetch('App.Pattern')[:id]
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      File.write(source_path(output), File.read(source_path(output)).sub('App.Pattern', 'App.Renamed'))
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(expressions(rebuilt)).not_to have_key('App.Pattern')
      expect(expressions(rebuilt).fetch('App.Renamed')[:id]).to eq(identifier)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      entry = manifest_entries(restored).find { _1['name'] == 'App.Renamed' }
      expect(entry).to include('id' => identifier, 'ruby_class' => 'App::Pattern',
                               'path' => 'app/regular_expressions/app/pattern.rb')
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Final.mpr'))
      expect(expressions(File.join(directory, 'Final.mpr')).fetch('App.Renamed')[:id]).to eq(identifier)
    end
  end

  %i[remove rename].each do |operation|
    it "rejects a referenced #{operation} before any native mutation" do
      Dir.mktmpdir('mxrb-reference-regular-expression-') do |directory|
        original = File.join(directory, 'Original.mpr')
        output = File.join(directory, 'ruby')
        fixture(original, referenced: true)
        Mxrb::Exporter.new(original, output, mode: :ruby).export!
        before = native_snapshot(original)
        if operation == :remove
          File.delete(source_path(output))
        else
          File.write(source_path(output), File.read(source_path(output)).sub('App.Pattern', 'App.Renamed'))
        end
        expect { Mxrb::RubyApp::Synchronizer.new(output, original).synchronize! }
          .to raise_error(Mxrb::ValidationError, /cannot #{operation} referenced regular expression/)
        expect(native_snapshot(original)).to eq(before)
      end
    end
  end

  it 'rejects wrong-family and wrong-module identities before changing any native document' do
    Dir.mktmpdir('mxrb-identity-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      fixture(original)
      Mxrb::Exporter.new(original, output, mode: :ruby).export!
      before = native_snapshot(original)
      identities = [expressions(original).fetch('Other.Foreign')[:id]]
      Mxrb.open(original) { |project| identities << project.modules.first.entities.first.id }
      identities.each do |identifier|
        File.write(source_path(output, 'new'), <<~RUBY)
          module App
            class NewPattern < Mxrb::RubyApp::RegularExpression
              mendix_name "App.NewPattern", id: #{identifier.inspect}
              expression "new"
            end
          end
        RUBY
        expect { Mxrb::RubyApp::Synchronizer.new(output, original).synchronize! }
          .to raise_error(Mxrb::ValidationError, /family|module|identity/)
        expect(native_snapshot(original)).to eq(before)
      end
    end
  end

  it 'rejects collisions with native document IDs even when they differ from the unit ID' do
    Dir.mktmpdir('mxrb-document-identity-regular-expression-') do |directory|
      original = File.join(directory, 'Original.mpr')
      fixture(original)
      foreign = expressions(original).fetch('Other.Foreign')
      identifier = SecureRandom.uuid
      mpr = Mxrb::IO::MprFile.open(original)
      begin
        mpr.update_unit(foreign.fetch(:id), foreign.fetch(:doc).merge('$ID' => identifier))
        before = mpr.query('SELECT UnitID, ContentsHash FROM Unit ORDER BY UnitID')
        writer = Mxrb::Writer.new(original, version: '11.12.1', modules: [])
        [['App', identifier], ['Other', foreign.fetch(:id)]].each do |module_name, id|
          expect do
            writer.synchronize_ruby_regular_expressions!(
              mpr, module_name:, expressions: [{ id:, name: 'NewPattern', properties: { 'Expression' => 'new' } }]
            )
          end.to raise_error(Mxrb::ValidationError, /identity/)
          expect(mpr.query('SELECT UnitID, ContentsHash FROM Unit ORDER BY UnitID')).to eq(before)
        end
      ensure
        mpr.close
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
