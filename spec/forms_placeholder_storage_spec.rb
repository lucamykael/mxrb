# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Forms::MprCodec do
  def hint = Mxrb::Forms::Text.coerce([Mxrb::Forms::Translation.new('en_US', 'Hint')])

  def text_box
    text = hint
    Mxrb::Forms::Node.build('Snippet') do
      name 'Form'
      widgets(:text_box) do
        name 'field'
        placeholder_template { template text }
      end
    end
  end

  def text_box_document(codec) = codec.encode(text_box)

  def stored_box(document) = document.fetch('Widgets').grep(Hash).first

  it 'stores a placeholder as a client template from Mendix 10' do
    %w[10.24.0 11.12.1].each do |version|
      box = stored_box(text_box_document(described_class.new(mendix_version: version)))

      expect(box).not_to have_key('Placeholder')
      expect(box.dig('PlaceholderTemplate', '$Type')).to eq('Forms$ClientTemplate')
    end
  end

  it 'stores a placeholder as plain text before Mendix 10 and when the version is unknown' do
    [described_class.new(mendix_version: '9.6.1'), described_class.new].each do |codec|
      box = stored_box(text_box_document(codec))

      expect(box).not_to have_key('PlaceholderTemplate')
      expect(box.dig('Placeholder', '$Type')).to eq('Texts$Text')
    end
  end

  it 'marks the parameters and variables of a snippet as Studio Pro does' do
    document = described_class.new(mendix_version: '11.12.1').encode(
      Mxrb::Forms::Node.build('Snippet') do
        name 'Form'
        set :parameters, []
        set :variables, []
      end
    )

    expect(document.fetch('Parameters').first).to eq(3)
    expect(document.fetch('Variables').first).to eq(3)
  end
end
# rubocop:enable Metrics/BlockLength

RSpec.describe Mxrb::StudioCompatibility do
  it 'keeps on Mendix 9.6.1 the actions that its schema stores as disabled during execution' do
    document = {
      '$Type' => 'Forms$Page',
      'Kept' => [{ '$Type' => 'Forms$NoAction', 'DisabledDuringExecution' => true },
                 { '$Type' => 'Forms$MicroflowAction', 'DisabledDuringExecution' => true }],
      'Removed' => { '$Type' => 'Forms$MicroflowSettings', 'DisabledDuringExecution' => true }
    }

    described_class.new('9.6.1.29396').apply_document!(document)

    expect(document.fetch('Kept').map { _1['DisabledDuringExecution'] }).to eq([true, true])
    expect(document.fetch('Removed')).not_to have_key('DisabledDuringExecution')
  end
end
