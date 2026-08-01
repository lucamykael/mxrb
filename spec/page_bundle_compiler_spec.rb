# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          page(:Home) do
            layout 'Demo.Shell'
            title 'Welcome'
            container(:body, class_name: 'body') { text :caption, caption: 'Hello' }
          end
        end
      end
      example.run
    end
  end

  it 'renders page content, layout metadata, and translated text as an ES module' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    bundle = described_class.new(source).compile(source.units_of('Forms$Page').first)
    expect(bundle.qualified_name).to eq('Demo.Home')
    expect(bundle.source).to include(
      'PageFragment', 'export const title = "Welcome"', 'Demo.Shell.Main',
      'mx-name-body body', '"Hello"'
    )
    expect(bundle.unsupported_widgets).to be_empty
  end

  it 'emits an auditable fallback for an unsupported widget type' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] << { '$Type' => 'Forms$UnknownWidget', 'Name' => 'future' }
    argument['Widgets'] << {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'futureCustom', 'Object' => {}
    }
    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include('mxrb-unsupported-widget', 'Forms$UnknownWidget')
    expect(bundle.unsupported_widgets).to eq(
      ['CustomWidgets$CustomWidget', 'Forms$UnknownWidget']
    )
  end

  it 'normalizes explicit render modes and translation fallbacks' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    expect(compiler.send(:render_mode, 'RenderMode' => 'Section')).to eq('section')
    expect(compiler.send(:render_mode, {})).to eq('div')
    expect(compiler.send(:translated_text, nil)).to eq('')
    expect(compiler.send(:translated_text, 'Items' => [
                           3, { 'LanguageCode' => 'pt_BR', 'Text' => 'Olá' }
                         ])).to eq('Olá')
    expect(compiler.send(:translated_text, 'Items' => [3])).to eq('')
  end
end

RSpec.describe Mxrb::Compiler::PageBundleBuilder do
  it 'replaces stale page sources and writes the support manifest' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) { page(:Home) { text :caption, caption: 'Hello' } }
      end
      web = File.join(root, 'web')
      FileUtils.mkdir_p(File.join(web, 'pages'))
      File.write(File.join(web, 'pages', 'Stale.js'), 'stale')
      bundles = described_class.new(Mxrb::Compiler::SourceModel.read(mpr), web).build
      expect(bundles.map(&:qualified_name)).to eq(['Demo.Home'])
      expect(File).not_to exist(File.join(web, 'pages', 'Stale.js'))
      expect(JSON.parse(File.read(File.join(web, 'mxrb-pages.json')))).to eq('Demo.Home' => [])
    end
  end
end

RSpec.describe Mxrb::Compiler::WidgetPackageExtractor do
  it 'extracts safe packages, ignores an absent widget directory, and rejects traversal' do
    Dir.mktmpdir do |root|
      web = File.join(root, 'web')
      expect(described_class.new(File.join(root, 'absent'), web).extract).to eq(0)
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      package = File.join(widgets, 'safe.mpk')
      Zip::File.open(package, create: true) do |zip|
        zip.get_output_stream('vendor/widget/Widget.mjs') { _1.write('export default {};') }
      end
      expect(described_class.new(root, web).extract).to eq(1)
      expect(File).to exist(File.join(web, 'widgets', 'vendor', 'widget', 'Widget.mjs'))

      unsafe = File.join(widgets, 'unsafe.mpk')
      allow(Zip::File).to receive(:open).with(unsafe).and_yield([
                                                                  instance_double(
                                                                    Zip::Entry, directory?: false,
                                                                                name: '../outside',
                                                                                get_input_stream: StringIO.new('x')
                                                                  )
                                                                ])
      expect { described_class.new(root, web).send(:extract_package, unsafe) }
        .to raise_error(Mxrb::CompilationError, /unsafe widget/)
    end
  end

  it 'reports corrupt widget archives' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      File.write(File.join(widgets, 'broken.mpk'), 'broken')
      expect { described_class.new(root, File.join(root, 'web')).extract }
        .to raise_error(Mxrb::CompilationError, /invalid widget package/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
