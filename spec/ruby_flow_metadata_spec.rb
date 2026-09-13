# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::RubyApp::FlowMetadata do # rubocop:disable Metrics/BlockLength
  around do |example|
    Dir.mktmpdir('mxrb-flow-metadata-') do |directory|
      @directory = directory
      example.run
    end
  end

  def export_flows # rubocop:disable Metrics/MethodLength
    source = File.join(@directory, 'Source.mpr')
    Mxrb.define(source) do
      mendix_version '10.18.0'
      self.module(:App) do
        microflow(:Shared) do
          return_type :string
          return_value "'before'"
        end
        nanoflow(:Shared) do
          return_type :integer
          return_value '42'
        end
      end
    end
    root = File.join(@directory, 'ruby-app')
    Mxrb::Exporter.new(source, root, mode: :ruby).export!
    [source, root]
  end

  def flow_documents(path)
    Mxrb.open(path) do |project|
      mod = project.modules.find { _1.name == 'App' }
      [*mod.microflows, *mod.nanoflows].to_h { [_1.id, project.mpr.parse_contents(project.mpr.unit(_1.id))] }
    end
  end

  def service_files(root) = Dir.glob(File.join(root, 'app', 'services', '**', '*.rb'))

  def metadata_path(root)
    File.join(root, '.mxrb', 'semantic_metadata.json')
  end

  def legacy_metadata_path(root)
    File.join(root, '.mxrb', 'mendix', '.mxrb', 'semantic_metadata.json')
  end

  it 'preserves homonymous microflow and nanoflow bodies exactly without public fingerprints' do
    source, root = export_flows
    text = service_files(root).map { File.read(_1) }.join
    expect(text).to include('flow :microflow', 'flow :nanoflow')
    expect(text).not_to include('body_fingerprint')
    expect(text).not_to match(/mendix_name[^\n]*\bid:/)
    application = Mxrb::RubyApp::Application.new(root)
    services = Mxrb::RubyApp::Registry.all(:service).values
    expect(services.map { _1.native_definition.fetch(:preserve_native_body) }).to eq([true, true])
    compiled = Mxrb::RubyApp.compile(root, File.join(@directory, 'Compiled.mpr'))
    expect(flow_documents(compiled)).to eq(flow_documents(source))
  ensure
    application&.close
  end

  it 'makes edited body source authoritative while retaining the other flow and unit identity' do
    source, root = export_flows
    original = flow_documents(source)
    file = service_files(root).find { File.read(_1).include?("'before'") }
    File.write(file, File.read(file).sub("'before'", "'after'"))
    compiled = Mxrb::RubyApp.compile(root, File.join(@directory, 'Edited.mpr'))
    rebuilt = flow_documents(compiled)

    expect(rebuilt.keys).to match_array(original.keys)
    nano_id = original.find { |_id, doc| doc['$Type'] == 'Microflows$Nanoflow' }.first
    expect(rebuilt.fetch(nano_id)).to eq(original.fetch(nano_id))
    Mxrb.open(compiled) do |project|
      flow = project.modules.find { _1.name == 'App' }.microflows.first
      expect(flow.objects.find { _1['$Type'] == 'Microflows$EndEvent' }.fetch('ReturnValue')).to eq("'after'")
    end
  end

  it 'fails explicitly when an existing service loses its metadata baseline' do
    _source, root = export_flows
    File.delete(metadata_path(root))
    File.delete(legacy_metadata_path(root))

    expect { Mxrb::RubyApp::Application.new(root) }
      .to raise_error(Mxrb::ValidationError, /requires its semantic metadata baseline/)
    expect { Mxrb::RubyApp.compile(root, File.join(@directory, 'MissingBaseline.mpr')) }
      .to raise_error(Mxrb::ValidationError, /requires its semantic metadata baseline/)
  end

  it 'retains support for legacy explicit fingerprints without a metadata sidecar' do
    source, root = export_flows
    entries = JSON.parse(File.read(metadata_path(root))).dig('modules', 'App', 'flows', 'Shared')
    manifest_entries = Mxrb::RubyApp::Manifest.load(root).modules.flat_map do |mod|
      mod.fetch('services') + mod.fetch('nanoflows')
    end
    metadata_by_id = entries.to_h { [_1.fetch('unit_id'), _1] }
    service_files(root).each do |path|
      text = File.read(path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      declaration = manifest_entries.find { (_1['ruby_path'] || _1['path']) == relative }
      expect(declaration).not_to be_nil
      entry = metadata_by_id.fetch(declaration.fetch('id'))
      text = text.sub(/(flow :\w+ do\n)/, "\\1    body_fingerprint #{entry.fetch('body_fingerprint').inspect}\n")
      File.write(path, text)
    end
    File.delete(metadata_path(root))
    File.delete(legacy_metadata_path(root))
    compiled = Mxrb::RubyApp.compile(root, File.join(@directory, 'Legacy.mpr'))

    expect(flow_documents(compiled).keys).to match_array(flow_documents(source).keys)
    expect(Mxrb::RubyApp::Registry.all(:service).values.map { _1.native_definition[:preserve_native_body] })
      .to eq([true, true])
  end

  it 'scopes metadata by unit and native type and restores nested contexts after failures' do
    _source, root = export_flows
    manifest = Mxrb::RubyApp::Manifest.load(root)
    entries = JSON.parse(File.read(metadata_path(root))).dig('modules', 'App', 'flows', 'Shared')
    micro = entries.find { _1['native_type'] == 'Microflows$Microflow' }
    id = micro.fetch('unit_id')
    empty_manifest = instance_double(
      Mxrb::RubyApp::Manifest, root: File.join(@directory, 'Other'), modules: [],
                               absolute_path: File.join(@directory, 'Other', 'project.rb')
    )
    described_class.with(manifest) do
      expect(described_class.for(id, 'Microflows$Microflow')).to eq(micro)
      expect(described_class.for(id, 'Microflows$Nanoflow')).to be_nil
      expect do
        described_class.with(empty_manifest) do
          expect(described_class.for(id, 'Microflows$Microflow')).to be_nil
          raise 'stop'
        end
      end.to raise_error('stop')
      expect(described_class.for(id, 'Microflows$Microflow')).to eq(micro)
    end
    expect(described_class.for(id, 'Microflows$Microflow')).to be_nil
  end

  it 'rejects malformed sidecars and still permits newly authored services without metadata' do
    _source, root = export_flows
    File.write(metadata_path(root), '{')
    expect { Mxrb::RubyApp::Application.new(root) }.to raise_error(Mxrb::SerializationError, /invalid flow metadata/)
    service = Class.new(Mxrb::RubyApp::Service) do
      mendix_name 'New.Flow'
      flow { return_value "'new'" }
    end
    expect(service.native_definition).to include(preserve_native_body: false, return_expression: "'new'")
  end
end
