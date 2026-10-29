# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/sync'
require 'mxrb/studio/structure'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe 'Studio synchronization generation reuse' do
  around do |example|
    Dir.mktmpdir('mxrb-sync-generation-') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:model) do
    path = File.join(@directory, 'app', 'App.mpr')
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:App) do
        entity(:Product) { string :Name }
        layout :Shell
        page(:Home) { layout 'App.Shell' }
        page(:List) { layout 'App.Shell' }
        microflow(:Recalculate) { return_value 'empty' }
      end
    end
    path
  end
  let(:ruby) do
    destination = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(model, destination, mode: :mendix).export!(parallel: false)
    destination
  end
  let(:sync) do
    Mxrb::Studio::Sync.new(model, ruby_root: ruby, state_root: File.join(@directory, 'state'), isolation: :process)
  end

  # Synchronization's generation (process isolation), seeded from `reuse`.
  def generate(name, reuse: nil)
    directory = File.join(@directory, name)
    sync.send(:generate, directory, reuse:)
    File.join(directory, 'App.mpr')
  end

  # The same generation in this process, reporting the pages and native module steps the writer wrote.
  def generate_here(name, reuse: nil)
    project = File.join(ruby, 'project.rb')
    target = File.join(@directory, name, 'App.mpr')
    FileUtils.mkdir_p(File.dirname(target))
    written = []
    allow_any_instance_of(Mxrb::Writer).to receive(:page_doc).and_wrap_original do |method, page, *rest, **options|
      written << page.fetch(:name).to_s
      method.call(page, *rest, **options)
    end
    allow_any_instance_of(Mxrb::Writer).to receive(:write_native_documents).and_wrap_original do |method, *arguments|
      written << 'native'
      method.call(*arguments)
    end
    with_environment('MXRB_OUTPUT_PATH' => target, Mxrb::Writer::REUSE_OUTPUT => reuse.to_s) do
      load project
    end
    [target, written.sort]
  end

  def with_environment(values)
    previous = values.to_h { [_1, ENV.fetch(_1, nil)] }
    values.each { ENV[_1] = _2 }
    yield
  ensure
    previous.each { ENV[_1] = _2 }
  end

  def opened(path, readonly: false)
    mpr = Mxrb::IO::MprFile.open(path, readonly:, apply_studio_compatibility: false)
    yield mpr
  ensure
    mpr&.close
  end

  def fingerprints(path) = sync.send(:fingerprints, path)
  def page_file(name) = File.join(ruby, 'modules/App/presentation/pages', "#{name.downcase}.rb")
  def entity_file = File.join(ruby, 'modules/App/domain/entities/product.rb')

  it 'keeps the pages and native documents whose definitions did not change, as a full generation writes them' do
    earlier, all = generate_here('earlier')
    expect(all).to eq(%w[Home List native])
    expect(opened(earlier, readonly: true, &:generation_digests)).to include('context', 'modules')

    File.write(page_file('List'), File.read(page_file('List')).sub('title "List"', 'title "Products"'))
    reused, written = generate_here('reused', reuse: earlier)
    expect(written).to eq(%w[List])
    full = generate('full')
    expect(fingerprints(reused)).to eq(fingerprints(full))
    expect(fingerprints(generate('seeded', reuse: earlier))).to eq(fingerprints(full))
  end

  it 'writes everything again when the module declares other documents or the project context changed' do
    earlier, = generate_here('earlier')
    product = File.read(entity_file)
    File.write(entity_file, "#{product}\nentity :Extra do\n  string :Code\nend\n")
    expect(generate_here('module', reuse: earlier).last).to eq(%w[Home List native])

    File.write(entity_file, product)
    expect(generate_here('same', reuse: earlier).last).to eq([])
    project = File.join(ruby, 'project.rb')
    File.write(project, File.read(project).sub('mendix_version "10.18.0"', 'mendix_version "10.19.0"'))
    expect(generate_here('context', reuse: earlier).last).to eq(%w[Home List native])
  end

  it 'starts from an MPR v2 generation with its external unit contents' do
    Mxrb.open(model, readonly: false) { _1.mpr.migrate_storage_format!(:v2) }
    earlier, = generate_here('earlier')
    expect(File).to be_directory(File.join(File.dirname(earlier), 'mprcontents'))
    File.write(page_file('List'), File.read(page_file('List')).sub('title "List"', 'title "Products"'))
    reused, written = generate_here('reused', reuse: earlier)
    expect(written).to eq(%w[List])
    expect(fingerprints(reused)).to eq(fingerprints(generate('full')))
  end

  describe Mxrb::Writer do
    let(:writer) { described_class.new(File.join(@directory, 'unused.mpr'), {}, 'earlier.mpr') }

    def digest(value) = writer.send(:definition_digest, value)

    it 'digests typed definitions by content, which is the same in every run' do
      forms = -> { Mxrb::Forms::Node.build('TextBox') { name 'Total' } }
      expect(digest(forms.call)).to eq(digest(forms.call))
      expect(digest(forms.call)).not_to eq(digest(Mxrb::Forms::Node.build('TextBox') { name 'Other' }))

      property = Mxrb::Pluggable::PropertyType.new(key: 'value', ruby_name: 'value', category: nil, caption: nil,
                                                   description: nil, prompt: nil, default: nil, value_type: nil)
      widget = Mxrb::Pluggable::WidgetType.new(
        id: 'com.example.Widget', name: 'Widget', description: nil, prompt: nil, studio_pro_category: nil,
        studio_category: nil, platform: nil, offline: nil, needs_context: nil, plugin: nil, help_url: nil,
        object_type: Mxrb::Pluggable::ObjectType.new(properties: [property])
      )
      pluggable = lambda do |value|
        Mxrb::Pluggable::Node.new(widget).tap do |node|
          node.object.instance_variable_get(:@assignments) << Mxrb::Pluggable::Assignment.new(property:, value:)
        end
      end
      expect(digest(pluggable.call('a'))).to eq(digest(pluggable.call('a')))
      expect(digest(pluggable.call('a'))).not_to eq(digest(pluggable.call('b')))

      settings = -> { Mxrb::Settings::Node.new('Settings$ServerConfiguration').set('Name', 'App') }
      expect(digest(settings.call)).to eq(digest(settings.call))
      values = lambda do
        [Mxrb::Settings::BinaryAsset.from_bytes("\x00".b), BSON::Binary.new("\x01".b),
         Mxrb::Forms::Expression.new(source: '1'), (+"\xff").force_encoding(Encoding::UTF_8), :symbol, 1, true, nil,
         { 'key' => ['value'] }]
      end
      expect(digest(values.call)).to eq(digest(values.call))
      expect(digest(Object.new)).to be_nil
      expect(digest(Float::NAN)).to be_nil
    end

    it 'reuses only an output whose generation digests share its context' do
      digests = { 'context' => 'same', 'modules' => { 'App' => {} } }
      stored = ->(value) { instance_double(Mxrb::IO::MprFile, generation_digests: value) }
      expect(writer.send(:reusable, stored.call(digests), digests)).to eq('App' => {})
      expect(writer.send(:reusable, stored.call(nil), digests)).to eq({})
      expect(writer.send(:reusable, stored.call(digests.merge('context' => 'other')), digests)).to eq({})
      expect(writer.send(:reusable, stored.call(digests), digests.merge('context' => nil))).to eq({})
      expect(described_class.new(File.join(@directory, 'unused.mpr'), {}, '')
                            .send(:reusable, stored.call(digests), digests)).to eq({})
    end
  end

  it 'reads no generation digests from a model no generation wrote, and writes none read-only' do
    opened(model) { _1.instance_variable_get(:@db).execute('DROP TABLE _MxrbGeneration') }
    opened(model, readonly: true) do |mpr|
      expect(mpr.generation_digests).to be_nil
      expect { mpr.write_generation_digests({}) }.to raise_error(Mxrb::ReadOnlyError)
    end
  end
end
# rubocop:enable Metrics
