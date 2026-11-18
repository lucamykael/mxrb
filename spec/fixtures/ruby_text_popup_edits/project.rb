# frozen_string_literal: true

load File.expand_path('../ruby_page_contracts/project.rb', __dir__)

# A native input with explicit, independently stored localized text containers.
module RubyTextPopupEditsFixture
  module_function

  def text(value)
    { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text', 'Items' => [3, {
      '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation', 'LanguageCode' => 'en_US', 'Text' => value
    }] }
  end

  def template(value)
    { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate',
      'Template' => text(value), 'Fallback' => text(''), 'Parameters' => [2] }
  end

  def input(value)
    return value if value.is_a?(Hash) && value['Name'] == 'DraftInput'

    children = value.is_a?(Hash) ? value.values : Array(value)
    children.filter_map { input(_1) if _1.is_a?(Hash) || _1.is_a?(Array) }.first
  end
end

Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'), readonly: false) do |project|
  page = project.modules.find { _1.name == 'Contracts' }.pages.find { _1.name == 'Editor' }
  raw = page.raw_document
  input = RubyTextPopupEditsFixture.input(raw)
  input.fetch('LabelText').fetch('Items')[1]['Text'] = ''
  input['LabelTemplate'] = nil
  input['PlaceholderTemplate'] = RubyTextPopupEditsFixture.template('Original placeholder')
  input['ScreenReaderLabel'] = RubyTextPopupEditsFixture.template('Original accessible name')
  project.mpr.update_unit(page.id, raw)
end
