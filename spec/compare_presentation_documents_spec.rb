# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Mxrb.compare on presentation documents' do
  def define_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) { page(:Home) { text 'message', caption: 'Original' } }
    end
  end

  def project_with_layout(path, &change)
    define_project(path)
    return path unless change

    layout = Mxrb.open(path) { |project| project.modules.flat_map(&:presentation_documents).first }
    change.call(layout.fetch(:doc))
    mpr = Mxrb::IO::MprFile.open(path, readonly: false)
    mpr.update_unit(layout.fetch(:id), layout.fetch(:doc))
    mpr.close
    path
  end

  def changes(&change)
    Dir.mktmpdir do |directory|
      left = project_with_layout(File.join(directory, 'left', 'App.mpr').tap { FileUtils.mkdir_p(File.dirname(_1)) })
      right = project_with_layout(File.join(directory, 'right', 'App.mpr').tap { FileUtils.mkdir_p(File.dirname(_1)) },
                                  &change)
      Mxrb.compare(left, right).differences
    end
  end

  it 'reports a field stored differently in a layout' do
    differences = changes { _1['Appearance']['Class'] = 'edited' }

    expect(differences).to contain_exactly(a_string_including('presentation_documents', 'Class', 'edited'))
  end

  it 'ignores identities, empty or false fields and empty collections' do
    expect(changes do |document|
      document['$ID'] = BSON::Binary.new(SecureRandom.bytes(16), :generic)
      document['Empty'] = ''
      document['Unset'] = nil
      document['Off'] = false
      document['Nothing'] = {}
      document['Items'] = [3]
    end).to be_empty
  end

  it 'reports a value where the other side has none' do
    expect(changes { _1['Extra'] = 0 }).to contain_exactly(a_string_including('Extra'))
    expect(changes { _1['Extra'] = [3, 'item'] }).to contain_exactly(a_string_including('Extra'))
  end

  describe 'pointers' do
    def comparator = Mxrb::Compare::Comparator.new('left', 'right')
    def normalized(value, kinds = {}) = comparator.send(:normalized_document, value, kinds)

    it 'treats a null pointer as absent and any other as an identity' do
      null = BSON::Binary.new("\0" * 16, :generic)
      real = BSON::Binary.new("\1" * 16, :generic)

      expect(normalized('Pointer' => null)).to eq({})
      expect(normalized('Pointer' => real)).to eq('Pointer' => :identity)
    end
  end

  describe 'the action of a widget value' do
    def comparator = Mxrb::Compare::Comparator.new('left', 'right')

    def widget(kind, disabled)
      id = BSON::Binary.new("\2" * 16, :generic)
      {
        '$Type' => 'CustomWidgets$CustomWidget',
        'Type' => { '$ID' => id, 'ValueType' => { 'Type' => kind } },
        'Property' => {
          '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => id,
          'Value' => { 'Action' => { '$Type' => 'Forms$NoAction', 'DisabledDuringExecution' => disabled } }
        }
      }
    end

    def normalized(document)
      comparator.send(:normalized_document, document, comparator.send(:widget_value_kinds, document))
    end

    it 'ignores it on a property that is not an action' do
      expect(normalized(widget('String', false))).to eq(normalized(widget('String', true)))
    end

    it 'keeps it on an action property' do
      expect(normalized(widget('Action', false))).not_to eq(normalized(widget('Action', true)))
    end

    it 'reads a property without a value and a list of them' do
      document = { 'Items' => [2, { '$Type' => 'CustomWidgets$WidgetProperty', 'Value' => nil }] }

      expect(normalized(document)).to eq('Items' => [2, { '$Type' => 'CustomWidgets$WidgetProperty' }])
    end
  end
end
# rubocop:enable Metrics/BlockLength
