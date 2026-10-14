# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# A button that opens a page with an object parameter passes it from its context,
# as Studio Pro 11.12.1 compiles it: e.g. argMap {param$Account: {widget:
# "p.Administration.Account_Overview.dataGrid21", source: "object"}} for a grid row,
# and {param$Game: {widget: "$Game"}} inside a data view of the page parameter.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          page(:Home) { layout 'Demo.Shell' }
          page(:Detail) { layout 'Demo.Shell' }
        end
      end
      example.run
    end
  end

  def object_parameter(name, entity)
    { 'Name' => name, 'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => entity } }
  end

  def open_detail = { '$Type' => 'Forms$FormAction', 'FormSettings' => { 'Form' => 'Demo.Detail' } }

  it 'passes object parameters from the innermost list, data view or page parameter' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    home, detail = %w[Home Detail].map { |name| source.units_of('Forms$Page').find { _1.document['Name'] == name } }
    detail.document['Parameters'] = [3, object_parameter('Item', 'Demo.Item')]
    compiler = described_class.new(source)
    compiler.instance_variable_set(:@unit, home)
    compiler.instance_variable_set(:@list_scopes, [])
    compiler.instance_variable_set(:@data_view_scopes, [])
    argument = -> { compiler.send(:open_page_config, open_detail)&.fetch(:argMap) }

    expect(argument.call).to be_nil

    home.document['Parameters'] = [3, object_parameter('Current', 'Demo.Item')]
    expect(argument.call).to eq('param$Item': { widget: '$Current', source: 'object' })

    compiler.instance_variable_set(:@data_view_scopes, [{ scope: 'p.Demo.Home.dv', entity: 'Demo.Item' }])
    expect(argument.call).to eq('param$Item': { widget: 'p.Demo.Home.dv', source: 'object' })

    compiler.instance_variable_set(:@data_view_scopes, [{ scope: 'p.Demo.Home.dv', entity: 'Demo.Item',
                                                          page_parameter: 'Current' }])
    expect(argument.call).to eq('param$Item': { widget: '$Current', source: 'object' })

    compiler.instance_variable_set(:@list_scopes, [{ scope: 'p.Demo.Home.grid', entity: 'Demo.Item' }, 'opaque'])
    expect(argument.call).to eq('param$Item': { widget: 'p.Demo.Home.grid', source: 'object' })

    detail.document['Parameters'] = [3, { 'Name' => 'Text', 'ParameterType' => { '$Type' => 'DataTypes$StringType' } }]
    expect(argument.call).to eq({})
  end

  it 'opens popup pages as resizable modals like Studio Pro' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    home = source.units_of('Forms$Page').find { _1.document['Name'] == 'Home' }
    compiler = described_class.new(source)
    compiler.instance_variable_set(:@unit, home)
    allow(compiler).to receive(:page_location).and_return('modal')

    detail = source.units_of('Forms$Page').find { _1.document['Name'] == 'Detail' }
    detail.document['PopupResizable'] = false
    expect(compiler.send(:open_page_config, open_detail).fetch(:config)).to include(location: 'modal', resizable: false)
    detail.document.delete('PopupResizable')
    expect(compiler.send(:open_page_config, open_detail).fetch(:config)).to include(resizable: true)
    allow(compiler).to receive(:page_location).and_return('content')
    expect(compiler.send(:open_page_config, open_detail).fetch(:config)).not_to have_key(:resizable)
    missing = { '$Type' => 'Forms$FormAction', 'FormSettings' => { 'Form' => 'Demo.Missing' } }
    expect(compiler.send(:open_page_config, missing)).to include(argMap: {})
  end
end

RSpec.describe Mxrb::Compiler::PageBundleBuilder do
  it 'reports inert widgets on every build and fails in strict mode' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          page(:Home) { layout 'Demo.Shell' }
        end
      end
      source = Mxrb::Compiler::SourceModel.read(mpr)
      expect { described_class.new(source, File.join(root, 'clean')).build }
        .to output(/Demo\.Shell: Forms\$NavigationTree/).to_stderr

      unit = source.units_of('Forms$Page').first
      unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }['Widgets'] <<
        { '$Type' => 'Forms$UnknownWidget', 'Name' => 'future' }
      expect { described_class.new(source, File.join(root, 'web')).build }
        .to output(/WARNING: 2 unsupported widget.*Demo\.Home: Forms\$UnknownWidget/m).to_stderr
      expect { described_class.new(source, File.join(root, 'strict'), strict: true).build }
        .to raise_error(Mxrb::CompilationError, /rendered inert/)
    end
  end
end

RSpec.describe Mxrb::Compiler::WebShellMaterializer do
  it 'fails loudly when the dev-mode page-cache pattern drifts instead of shipping stale pages' do
    Dir.mktmpdir do |root|
      chunks = File.join(root, 'dist', 'chunks')
      FileUtils.mkdir_p(chunks)
      File.write(File.join(chunks, 'drift.js'),
                 'let t=window.mx.getConfig("isDevModeEnabled")?"":`?${window.mx.getConfig("cachebust")}`')
      expect { described_class.new(root, version: '11.12.1').materialize_dynamic_imports }
        .to raise_error(Mxrb::CompilationError, /page-cache pattern drifted for Mendix 11\.12\.1/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
