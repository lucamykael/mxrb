# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::SourceIdentity do
  around do |example|
    Dir.mktmpdir('mxrb-source-order-') do |directory|
      @directory = directory
      example.run
    end
  end

  after { Mxrb::RubyApp::Registry.reset! }

  def entry(name = 'Existing', id: '11111111-1111-4111-8111-111111111111')
    { 'name' => "App.#{name}", 'ruby_class' => "App::#{name}", 'id' => id,
      'path' => 'app/models/app/existing.rb' }
  end

  def context(entries = [entry])
    manifest = Mxrb::RubyApp::Manifest.new(
      @directory, 'mode' => 'ruby', 'modules' => [{ 'name' => 'App', 'models' => entries }]
    )
    described_class.new(manifest)
  end

  def owner(name, ruby_class: "App::#{name}")
    double(name: ruby_class, mendix_name: "App.#{name}", mendix_id: '', resolve_record_identities!: nil)
  end

  # rubocop:disable Metrics/ParameterLists
  def bind(resolver, declaration, path: entry.fetch('path'), id: nil, kind: 'record', renamed_from: nil)
    resolver.load_file(File.join(@directory, path)) do
      resolver.resolve(declaration, kind, declaration.mendix_name, id:, renamed_from:)
    end
  end
  # rubocop:enable Metrics/ParameterLists

  [%w[Added Existing], %w[Existing Added]].each do |order|
    it "resolves #{order.join(' then ')} without transferring an existing identity" do
      resolver = context
      resolved = order.to_h { |name| [name, bind(resolver, owner(name))] }

      expect(resolved).to eq('Added' => '', 'Existing' => entry.fetch('id'))
      expect(resolver.finalize!).to equal(resolver)
    end
  end

  it 'allows new declarations before an existing class that moves to a later file' do
    resolver = context
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'), path: 'app/models/app/z_moved.rb')).to eq(entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'recognizes matched legacy entries even when their native identity is empty' do
    resolver = context([entry(id: '')])
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'))).to eq('')
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'reserves every identity in a shared file independently of declaration order' do
    other = entry('Other', id: '22222222-2222-4222-8222-222222222222')
    resolver = context([entry, other])
    resolved = %w[Added Other Existing].to_h { |name| [name, bind(resolver, owner(name))] }

    expect(resolved).to eq('Added' => '', 'Other' => other.fetch('id'), 'Existing' => entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
  end

  it 'still rejects unmatched replacements instead of guessing a rename by position' do
    resolver = context
    expect(bind(resolver, owner('Changed'))).to eq('')

    expect { resolver.finalize! }
      .to raise_error(Mxrb::ValidationError, /cannot distinguish a new declaration from a rename/)
  end

  it 'binds an explicit entity rename to its existing private identity' do
    resolver = context
    renamed = owner('Renamed')

    expect(bind(resolver, renamed, renamed_from: 'App.Existing')).to eq(entry.fetch('id'))
    expect(resolver.finalize!).to equal(resolver)
    expect { resolver.validate_entity_names! }.not_to raise_error
  end

  it 'does not let one resolved declaration hide another unclaimed identity' do
    other = entry('Other', id: '22222222-2222-4222-8222-222222222222')
    resolver = context([entry, other])
    expect(bind(resolver, owner('Added'))).to eq('')
    expect(bind(resolver, owner('Existing'))).to eq(entry.fetch('id'))

    expect { resolver.finalize! }.to raise_error(Mxrb::ValidationError, /cannot distinguish/)
  end

  it 'keeps explicit legacy IDs and rejects duplicate claims immediately' do
    resolver = context
    expect(bind(resolver, owner('Existing', ruby_class: 'App::RenamedClass'), id: entry.fetch('id')))
      .to eq(entry.fetch('id'))
    expect { bind(resolver, owner('Impostor'), id: entry.fetch('id')) }
      .to raise_error(Mxrb::ValidationError, /claim the same record identity/)
  end

  it 'still rejects changing the family of an existing Ruby class' do
    resolver = context

    expect { bind(resolver, owner('Existing'), kind: 'page') }
      .to raise_error(Mxrb::ValidationError, /cannot change document family/)
  end

  it 'compiles and reexports a new model before an existing one with both identities preserved' do
    source = File.join(@directory, 'Source.mpr')
    root = File.join(@directory, 'ruby')
    Mxrb.define(source) do
      mendix_version '11.12.1'
      self.module(:App) { entity(:Existing) { string :Title } }
    end
    original = Mxrb.open(source) { _1.modules.find { |mod| mod.name == 'App' }.entities.first.id }
    Mxrb::Exporter.new(source, root, mode: :ruby).export!
    manifest = Mxrb::RubyApp::Manifest.load(root)
    model = manifest.modules.find { _1.fetch('name') == 'App' }.fetch('models').first
    path = File.join(root, model.fetch('path'))
    existing_source = File.read(path)
    added_source = <<~RUBY
      module App
        class Added < Mxrb::RubyApp::Record
          mendix_name 'App.Added'
          attribute :title, type: :string, mendix_name: 'Title'
        end
      end
    RUBY
    expect(existing_source).to include("module App\n")
    edited_source = existing_source.sub("module App\n", "#{added_source}module App\n")
    File.write(path, edited_source)

    rebuilt = Mxrb::RubyApp.compile(root, File.join(@directory, 'Compiled.mpr'))
    identities = model_identities(rebuilt)
    expect(identities.fetch('Existing')).to eq(original)
    expect(identities.keys).to contain_exactly('Existing', 'Added')
    expect(identities.fetch('Added')).not_to eq(original)
    expect(identities.fetch('Added')).not_to be_empty

    restored = File.join(@directory, 'restored')
    Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
    restored_module = Mxrb::RubyApp::Manifest.load(restored).modules.find { _1.fetch('name') == 'App' }
    restored_models = restored_module.fetch('models')
    expect(restored_models.map { _1.fetch('path') }.uniq).to eq([model.fetch('path')])
    expect(File.read(File.join(restored, model.fetch('path')))).to eq(edited_source)
    final_mpr = Mxrb::RubyApp.compile(restored, File.join(@directory, 'Restored.mpr'))
    expect(model_identities(final_mpr)).to eq(identities)
  end

  def model_identities(path)
    Mxrb.open(path) do |project|
      project.modules.find { _1.name == 'App' }.entities.to_h { [_1.name, _1.id] }
    end
  end
end
# rubocop:enable Metrics/BlockLength
