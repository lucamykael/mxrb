# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/certify_presentation_edits', __dir__)

RSpec.describe 'Legacy presentation projection' do # rubocop:disable Metrics/BlockLength
  def decode(document)
    Mxrb::Model::Page.allocate.tap { _1.decode(document) }
  end

  let(:label) { { '$Type' => 'Forms$Label', 'Name' => 'message', 'Caption' => 'Before' } }

  it 'reads singular roots and nested slots without changing the native document' do
    document = { 'Widget' => { '$Type' => 'Forms$DivContainer', 'Name' => 'body', 'Widget' => label } }
    original = Marshal.dump(document)
    expect(decode(document).widgets.first.fetch(:children).first)
      .to include(type: :text, name: 'message', options: { caption: 'Before' })
    expect(Marshal.dump(document)).to eq(original)
    expect(decode('Widget' => nil).widgets).to eq([])
    expect(decode('Widgets' => [2], 'Widget' => label).widgets).to eq([])
  end

  it 'projects singular layout arguments and footer slots' do
    view = { '$Type' => 'Forms$DataView', 'Name' => 'view', 'Widget' => label, 'FooterWidget' => label }
    document = { 'FormCall' => { 'Arguments' => [2, { 'Widget' => view }] } }
    widget = decode(document).widgets.first
    expect(widget.values_at(:body, :footer).map { _1.first[:name] }).to eq(%w[message message])
  end

  it 'reads legacy entity and association paths' do
    parser = Mxrb::Model::Page.allocate
    expect(parser.send(:parse_data_view_source, { '$Type' => 'Forms$DataViewSource', 'EntityPath' => 'App.Item' }))
      .to include(kind: :context, entity: 'App.Item')
    expect(parser.send(:parse_data_view_source,
                       { '$Type' => 'Forms$DataViewSource', 'EntityPath' => 'App.Owner_Item/App.Item' }))
      .to include(kind: :association, steps: [{ association: 'App.Owner_Item', entity: 'App.Item' }])
  end

  it 'certifies the pinned Mendix 7 edits entirely through public Ruby without a runtime copy' do
    fixture = ENV.fetch('MXRB_CONNECTOR_FIXTURE')
    plan = JSON.parse(File.read(File.join(__dir__, 'fixtures/presentation_edits/cases.json')))
    test_case = plan.fetch('cases').find { _1.fetch('label') == 'mendix7' }
    expect(test_case.fetch('edits').map { _1.fetch('file') }).to all(start_with('app/'))
    test_case['mpr'] = File.basename(fixture)
    Dir.mktmpdir do |root|
      result = PresentationEditCertification.certify(test_case, File.dirname(fixture), root)
      expect(result).to include(passed: true, version: '7.5.0')
      layout = File.read(File.join(root, 'mendix7/ruby/app/presentation/navigation_layouts.rb'))
      expect(layout).to include('placeholder "Content"', '"navigationTree2"', '"sidebarToggle1"')
      snippet = File.read(File.join(root, 'mendix7/ruby/app/presentation/unit_testing.rb'))
      expect(snippet).to include('caption: "MXRB certified snippet 7"')
      expect(snippet).not_to include('native_fragment(')
    end
  end
end
