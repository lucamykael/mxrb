# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe Mxrb::RubyApp::WidgetStyles do # rubocop:disable Metrics/BlockLength
  def package(path, files)
    Zip::File.open(path, create: true) do |archive|
      files.each { |name, contents| archive.get_output_stream(name) { _1.write(contents) } }
    end
  end

  it 'bundles the styles of the used widgets with their assets, as MxBuild does' do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'widgets'))
      package(File.join(root, 'widgets', 'b.mpk'),
              'com/b/B.css' => '.b{background:url(com/b/assets/arrow.svg)}', 'com/b/assets/arrow.svg' => '<svg/>',
              'com/b/B.js' => 'code', 'B.xml' => '<widget/>', 'com/c/C.css' => '.c{}', 'com/c/assets/c.svg' => 'c')
      package(File.join(root, 'widgets', 'a.mpk'), 'com/a/A.css' => '.a{}')
      File.write(File.join(root, 'widgets', 'broken.mpk'), 'not a zip')
      destination = File.join(root, 'out', 'widgets')
      FileUtils.mkdir_p(File.join(destination, 'stale'))

      described_class.write(root, destination, %w[com.b.B com.a.A])

      expect(File.read(File.join(destination, 'widgets.css')))
        .to eq(".a{}\n.b{background:url(com/b/assets/arrow.svg)}")
      expect(File.read(File.join(destination, 'com/b/assets/arrow.svg'))).to eq('<svg/>')
      expect(Dir.children(destination).sort).to eq(%w[com widgets.css])
      expect(Dir.children(File.join(destination, 'com'))).to eq(%w[b])
    end
  end

  it 'writes an empty bundle without widget packages and skips unsafe entry names' do
    Dir.mktmpdir do |root|
      described_class.write(root, File.join(root, 'widgets-out'), [])
      expect(File.read(File.join(root, 'widgets-out', 'widgets.css'))).to eq('')
    end
    expect(described_class.safe?('com/a/A.css')).to be(true)
    expect(described_class.safe?('../A.css')).to be(false)
    expect(described_class.safe?('/etc/A.css')).to be(false)
  end

  it 'collects the pluggable widgets of pages, snippets and layouts' do
    widget = ->(id) { { '$Type' => 'CustomWidgets$CustomWidget', 'Type' => { 'WidgetId' => id } } }
    page = double('page', name: 'Home', raw_document: { 'Widgets' => [2, widget.call('com.a.A')] })
    mod = double('module', name: 'App', pages: [page],
                           presentation_documents: [{ name: 'Layout', doc: { 'Widgets' => [widget.call('com.b.B')] } }])
    expect(described_class.widget_ids(double('project', modules: [mod])).to_a).to eq(%w[com.a.A com.b.B])
  end
end
