# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
PRESENTATION_DOCUMENT_TYPES = %w[
  Forms$Layout Forms$PageTemplate Forms$BuildingBlock Forms$Snippet
].freeze

RSpec.describe 'semantic presentation documents' do
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
      ruby = files.map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'layout_document :Shell', 'page_template_document :Starter',
        'building_block_document :Card', 'snippet_document :Summary',
        ':node_type => "Forms$DivContainer"', ':collection =>', ':binary =>'
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      PRESENTATION_DOCUMENT_TYPES.each { expect(native_source).not_to include(_1) }

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(presentation_documents(rebuilt)).to eq(presentation_documents(source))
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

  def documents # rubocop:disable Metrics/AbcSize
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
      documents = project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [unit['UnitID'], document] if PRESENTATION_DOCUMENT_TYPES.include?(document['$Type'])
      end
      documents.to_h
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
