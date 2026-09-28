# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
PRESENTATION_DOCUMENT_TYPES = %w[
  Forms$Layout Forms$PageTemplate Forms$BuildingBlock Forms$Snippet
].freeze

RSpec.describe 'semantic presentation documents' do
  it 'builds every reusable presentation document through schema-checked blocks' do
    harness = Class.new do
      include Mxrb::Dsl::PresentationDocuments

      attr_reader :native_documents

      def initialize = (@native_documents = [])

      def native_document(name, **options)
        @native_documents << options.merge(name:)
      end
    end.new

    layout = harness.layout_document('Shell') {}
    template = harness.page_template_document('Overview') { |node| node.name 'Authored' }
    block = harness.building_block_document('Card') {}
    snippet = harness.snippet_document('Details') {}

    expect([layout, template, block, snippet].map { _1.schema_type.name })
      .to eq(%w[Layout PageTemplate BuildingBlock Snippet])
    expect(layout.name).to eq('Shell')
    expect(template.name).to eq('Authored')
    expect(harness.native_documents.map { _1[:type] })
      .to eq(%w[Forms$Layout Forms$PageTemplate Forms$BuildingBlock Forms$Snippet])

    value = harness.send(:presentation_value_document, { Object.new => { map: { nested: 1 } } })
    expect(value.values.first).to eq(nested: 1)
  end

  it 'round-trips reusable form documents without native BSON declarations' do
    Dir.mktmpdir('mxrb-presentation-documents-') do |dir|
      source = File.join(dir, 'Presentation.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Presentation) {}
      end
      insert_documents(source)

      Mxrb::Exporter.new(source, exported).export!
      files = Dir[File.join(exported, 'modules', 'Presentation', 'presentation', '**', '*.rb')]
              .reject { File.basename(_1) == 'presentation.rb' }
      ruby = files.map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'layout_document :Shell do', 'page_template_document :Starter do',
        'building_block_document :Card do', 'snippet_document :Summary do',
        'widgets(:div_container) do',
        'image_data Mxrb::Forms::BinaryAsset.read(File.join(__dir__, '
      )
      expect(ruby).not_to include(
        'native_document', 'deep_structure:', 'bson_binary(', '$ID', 'unit_id:',
        'node_type:', 'collection:', 'binary:', '=>', '{', '}'
      )
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      PRESENTATION_DOCUMENT_TYPES.each { expect(native_source).not_to include(_1) }

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(presentation_documents(rebuilt)).to eq(presentation_documents(source))
    end
  end

  it 'adds, changes, and removes reusable documents with stable identities across two cycles' do
    Dir.mktmpdir('mxrb-presentation-authority-') do |dir|
      source = File.join(dir, 'Presentation.mpr')
      first_export = File.join(dir, 'ruby-one')
      first_rebuild = File.join(dir, 'rebuilt-one.mpr')
      second_export = File.join(dir, 'ruby-two')
      second_rebuild = File.join(dir, 'rebuilt-two.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Presentation) {}
      end
      insert_documents(source)
      original = presentation_raw_documents(source)

      Mxrb::Exporter.new(source, first_export).export!
      presentation = File.join(first_export, 'modules', 'Presentation', 'presentation')
      layout_path = File.join(presentation, 'layouts', 'shell.rb')
      layout_source = File.read(layout_path)
      changed_layout = layout_source.sub('canvas_width 800', 'canvas_width 960')
      expect(changed_layout).not_to eq(layout_source)
      File.write(layout_path, changed_layout)

      snippet_path = File.join(presentation, 'snippets', 'summary.rb')
      added_path = File.join(presentation, 'snippets', 'added.rb')
      added_source = File.read(snippet_path)
                         .sub('snippet_document :Summary', 'snippet_document :Added')
                         .sub('name "Summary"', 'name "Added"')
      expect(added_source).to include('snippet_document :Added', 'name "Added"')
      File.write(added_path, added_source)
      FileUtils.rm(snippet_path)

      aggregator = File.join(presentation, 'presentation.rb')
      lines = File.read(aggregator).lines.reject { _1.include?('summary.rb') }
      lines << "evaluate File.join(__dir__, \"snippets\", \"added.rb\")\n"
      File.write(aggregator, lines.join)
      expect(File.read(aggregator)).not_to include('summary.rb')

      generate(first_export, first_rebuild)
      expect(Mxrb.validate(first_rebuild)).to be_valid
      rebuilt = presentation_raw_documents(first_rebuild)
      expect(rebuilt).not_to have_key(['Forms$Snippet', 'Summary'])
      expect(rebuilt).to have_key(['Forms$Snippet', 'Added'])
      expect(rebuilt.fetch(['Forms$Layout', 'Shell']).fetch('CanvasWidth')).to eq(960)
      %w[Forms$Layout Forms$PageTemplate Forms$BuildingBlock].each do |type|
        key = original.keys.find { _1.first == type }
        expect(native_ids(rebuilt.fetch(key))).to contain_exactly(*native_ids(original.fetch(key)))
      end

      Mxrb::Exporter.new(first_rebuild, second_export).export!
      generate(second_export, second_rebuild)
      expect(Mxrb.validate(second_rebuild)).to be_valid
      expect(presentation_raw_documents(second_rebuild)).to eq(rebuilt)
    end
  end

  def insert_documents(path)
    mpr = Mxrb::IO::MprFile.open(path)
    module_id = mpr.units_by_containment('Modules').first.fetch('UnitID')
    documents.each do |document|
      mpr.insert_unit(
        container_uuid: module_id, containment_name: 'Documents', contents_doc: document
      )
    end
  ensure
    mpr&.close
  end

  def documents
    widgets = Mxrb::IO::BsonCodec.build_array([container_widget], marker: 2)
    [
      base_document('Forms$Layout', 'Shell').merge(
        'Appearance' => appearance,
        'Content' => node(
          'Forms$WebLayoutContent', 'LayoutCall' => nil,
                                    'LayoutType' => 'Responsive',
                                    'Widgets' => widgets
        )
      ),
      base_document('Forms$PageTemplate', 'Starter').merge(
        'Appearance' => appearance, 'DisplayName' => 'Starter', 'DocumentationUrl' => '',
        'ImageData' => BSON::Binary.new('preview'),
        'LayoutCall' => node('Forms$LayoutCall', 'Arguments' => Mxrb::IO::BsonCodec.build_array([]),
                                                 'Form' => 'Presentation.Shell'),
        'TemplateCategory' => 'General', 'TemplateCategoryWeight' => 1,
        'TemplateType' => node('Forms$RegularPageTemplateType')
      ),
      base_document('Forms$BuildingBlock', 'Card').merge(
        'DisplayName' => 'Card', 'DocumentationUrl' => '',
        'ImageData' => BSON::Binary.new('preview'), 'Platform' => 'Web',
        'TemplateCategory' => 'General', 'TemplateCategoryWeight' => 1, 'Widgets' => widgets
      ),
      base_document('Forms$Snippet', 'Summary').merge(
        'Parameters' => Mxrb::IO::BsonCodec.build_array([], marker: 2), 'Type' => 'Web',
        'Variables' => Mxrb::IO::BsonCodec.build_array([], marker: 2), 'Widgets' => widgets
      )
    ]
  end

  def base_document(type, name)
    {
      '$Type' => type, 'Name' => name, 'CanvasHeight' => 600, 'CanvasWidth' => 800,
      'Documentation' => '', 'Excluded' => false, 'ExportLevel' => 'Hidden'
    }
  end

  def container_widget
    node(
      'Forms$DivContainer',
      'Appearance' => appearance,
      'ConditionalVisibilitySettings' => nil,
      'Name' => 'content',
      'Widgets' => Mxrb::IO::BsonCodec.build_array([], marker: 2)
    )
  end

  def appearance
    node(
      'Forms$Appearance',
      'Class' => '',
      'DesignProperties' => Mxrb::IO::BsonCodec.build_array([], marker: 3),
      'DynamicClasses' => '',
      'Style' => ''
    )
  end

  def node(type, fields = {})
    { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(fields)
  end

  def presentation_documents(path)
    Mxrb.open(path) do |project|
      codec = Mxrb::Forms::MprCodec.new
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless PRESENTATION_DOCUMENT_TYPES.include?(document['$Type'])

        model = codec.decode(document)
        if (property = model.schema_type.property(:image_data)) &&
           (asset = model.fetch(property.name)) && !asset.bytes.empty?
          model.set(property.name, asset.at('preview'))
        end
        key = [document.fetch('$Type'), document.fetch('Name')]
        [key, [unit.fetch('UnitID'), Mxrb::Forms::SourceEmitter.new.emit(model)]]
      end.to_h
    end
  end

  def presentation_raw_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless PRESENTATION_DOCUMENT_TYPES.include?(document['$Type'])

        [[document.fetch('$Type'), document.fetch('Name')], document]
      end.to_h
    end
  end

  def native_ids(value)
    case value
    when Hash
      [value['$ID'], *value.values.flat_map { native_ids(_1) }].compact
    when Array
      value.drop(value.first.is_a?(Integer) ? 1 : 0).flat_map { native_ids(_1) }
    else
      []
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
