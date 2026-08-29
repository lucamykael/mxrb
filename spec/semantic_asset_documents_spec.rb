# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'semantic asset documents' do
  it 'round-trips images and custom icons as Ruby declarations' do
    Dir.mktmpdir('mxrb-assets-') do |dir|
      source = File.join(dir, 'Assets.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_project(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = Dir[File.join(exported, 'modules', 'Assets', 'presentation', 'assets', '**', '*.rb')]
             .map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'image_collection :Images', 'custom_icon_collection :Icons',
        ':format => "Png"', ':character_code => 65', ':tags =>'
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(asset_documents(rebuilt)).to eq(asset_documents(source))
    end
  end

  def define_project(path)
    encoded_image = Base64.strict_encode64('png')
    encoded_font = Base64.strict_encode64('font')
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Assets) do
        image_collection :Images, images: [{
          id: SecureRandom.uuid, name: 'Logo', format: 'Png',
          data: { data: encoded_image, subtype: :generic }
        }]
        custom_icon_collection(
          :Icons,
          collection_class: 'icons', prefix: 'ico',
          font: { data: encoded_font, subtype: :generic },
          icons: [{
            id: SecureRandom.uuid, name: 'Add', character_code: 65,
            tags: %w[create plus], tags_marker: 2
          }]
        )
      end
    end
  end

  def asset_documents(path)
    types = %w[Images$ImageCollection CustomIcons$CustomIconCollection]
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [unit['UnitID'], document] if types.include?(document['$Type'])
      end.to_h
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
