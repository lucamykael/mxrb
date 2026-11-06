# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Mxrb.compare on stored pages' do
  def comparator = Mxrb::Compare::Comparator.new('left', 'right')
  def stored(document) = comparator.send(:stored_document, document)

  def project(path)
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) { page(:Home) { text 'message', caption: 'Original' } }
    end
    path
  end

  def stored_page(path)
    Mxrb.open(path) do |opened|
      raw = opened.all_units.find { opened.parse_bson(_1)['$Type'] == 'Forms$Page' }
      [raw['UnitID'], opened.parse_bson(raw)]
    end
  end

  def edit_page(path)
    id, document = stored_page(path)
    yield document
    mpr = Mxrb::IO::MprFile.open(path, readonly: false)
    mpr.update_unit(id, document)
    mpr.close
    path
  end

  def differences(&change)
    Dir.mktmpdir do |directory|
      left = project(File.join(directory, 'left', 'App.mpr'))
      right = edit_page(project(File.join(directory, 'right', 'App.mpr')), &change)
      Mxrb.compare(left, right).differences
    end
  end

  it 'reports a stored field the page summary does not read' do
    expect(differences { _1['Extra'] = 'stored' }).to contain_exactly(a_string_including('pages', 'Extra', 'stored'))
  end

  it 'treats an unedited page as identical' do
    expect(differences { nil }).to be_empty
  end

  describe 'collection markers' do
    it 'accepts the default marker where Studio Pro stores another' do
      left = { '$Type' => 'Forms$DivContainer', 'Widgets' => [3, { '$Type' => 'Forms$Text' }] }
      right = { '$Type' => 'Forms$DivContainer', 'Widgets' => [2, { '$Type' => 'Forms$Text' }] }

      expect(stored(left)).to eq(stored(right))
    end

    it 'accepts the default marker for the roles of a page' do
      expect(stored('$Type' => 'Forms$Page', 'AllowedModuleRoles' => [3, 'App.User']))
        .to eq(stored('$Type' => 'Forms$Page', 'AllowedModuleRoles' => [1, 'App.User']))
    end

    it 'still reports the marker of any other collection' do
      left = { '$Type' => 'Forms$Snippet', 'Parameters' => [3, { '$Type' => 'Forms$SnippetParameter' }] }
      right = { '$Type' => 'Forms$Snippet', 'Parameters' => [2, { '$Type' => 'Forms$SnippetParameter' }] }

      expect(stored(left)).not_to eq(stored(right))
    end

    it 'leaves a value that is not a collection alone' do
      expect(stored('$Type' => 'Forms$DivContainer', 'Widgets' => 'odd')).to include('Widgets' => 'odd')
    end
  end

  describe 'a class next to its appearance' do
    def container(flat, appearance)
      { '$Type' => 'Forms$DivContainer', 'Class' => flat, 'Appearance' => { 'Class' => appearance } }
    end

    it 'ignores the copy of the appearance class' do
      expect(stored(container('card', 'card')))
        .to eq('$Type' => 'Forms$DivContainer', 'Appearance' => { 'Class' => 'card' })
    end

    it 'reports a class the appearance does not hold' do
      expect(stored(container('card', 'other'))).to include('Class' => 'card')
    end

    it 'keeps the class of a widget without an appearance' do
      expect(stored('$Type' => 'Forms$DivContainer', 'Class' => 'card')).to include('Class' => 'card')
    end
  end

  describe 'the direction of a sort item' do
    def item(fields) = { '$Type' => 'Forms$GridSortItem', **fields }

    it 'ignores SortDirection, which MxBuild compiles as ascending' do
      expect(stored(item('SortDirection' => 'Descending'))).to eq(stored(item('SortOrder' => 'Ascending')))
    end

    it 'reports a rebuild that turns it into a descending order' do
      expect(stored(item('SortDirection' => 'Descending'))).not_to eq(stored(item('SortOrder' => 'Descending')))
    end

    it 'reads SortOrder when both are stored' do
      both = item('SortOrder' => 'Descending', 'SortDirection' => 'Ascending')

      expect(stored(both)).to eq(stored(item('SortOrder' => 'Descending')))
    end

    it 'reads an item without a direction as ascending' do
      expect(stored(item('AttributeRef' => 'App.Item.Name'))).to include('SortOrder' => 'Ascending')
    end

    it 'leaves the same field of another type alone' do
      expect(stored('$Type' => 'Forms$Other', 'SortDirection' => 'Descending'))
        .to include('SortDirection' => 'Descending')
    end
  end

  describe 'the autofocus of a page' do
    it 'treats the default as absent' do
      expect(stored('$Type' => 'Forms$Page', 'Autofocus' => 'Off')).to eq('$Type' => 'Forms$Page')
    end

    it 'reports any other value' do
      expect(stored('$Type' => 'Forms$Page', 'Autofocus' => 'DesktopOnly')).to include('Autofocus' => 'DesktopOnly')
    end

    it 'leaves the same field of another type alone' do
      expect(stored('$Type' => 'Forms$Other', 'Autofocus' => 'Off')).to include('Autofocus' => 'Off')
    end
  end

  describe 'the text template of a widget value' do
    def widget(kind, text)
      id = BSON::Binary.new("\2" * 16, :generic)
      {
        '$Type' => 'CustomWidgets$CustomWidget',
        'Type' => { '$ID' => id, 'ValueType' => { 'Type' => kind } },
        'Property' => {
          '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => id,
          'Value' => { 'TextTemplate' => { '$Type' => 'Forms$ClientTemplate', 'Text' => text } }
        }
      }
    end

    it 'ignores it on a property of another kind' do
      expect(stored(widget('Widgets', 'a'))).to eq(stored(widget('Widgets', 'b')))
    end

    it 'keeps it on a text template property' do
      expect(stored(widget('TextTemplate', 'a'))).not_to eq(stored(widget('TextTemplate', 'b')))
    end
  end
end
# rubocop:enable Metrics/BlockLength
