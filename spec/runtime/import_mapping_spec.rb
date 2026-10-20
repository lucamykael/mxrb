# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The branches of a JSON import mapping that the native oracle in
# spec/fixtures/native_import_mapping does not reach.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::ImportMapping do
  before(:all) do
    @work = Dir.mktmpdir
    previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
    ENV['MXRB_OUTPUT_PATH'] = File.join(@work, 'Oracle.mpr')
    load 'spec/fixtures/native_import_mapping/project.rb'
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  after(:all) { FileUtils.rm_rf(@work) }

  around do |example|
    Mxrb.open(File.join(@work, 'Oracle.mpr')) do |project|
      @project = project
      example.run
    end
  end

  def interpreter(**options)
    Mxrb::Runtime::Native::Interpreter.new(@project, **options)
  end

  def customer(handling:, backup: '', key: true)
    {
      'kind' => 'object', 'element_type' => 'Object', 'path' => ['(Object)'], 'entity' => 'Views.Customer',
      'association' => '', 'attribute' => '', 'type' => '', 'key' => false, 'handling' => handling,
      'backup' => backup, 'converter' => '',
      'children' => [
        { 'kind' => 'value', 'element_type' => 'Value', 'path' => %w[(Object) code], 'entity' => '',
          'association' => '', 'attribute' => 'Code', 'type' => 'String', 'key' => key, 'handling' => '',
          'backup' => '', 'converter' => '', 'children' => [] }
      ]
    }
  end

  def mapping(root, runtime, associations: runtime.instance_variable_get(:@associations), converter: nil)
    described_class.new({ 'elements' => [root] }, store: runtime.store, associations:, converter:)
  end

  it 'ignores, refuses or creates an object a Find does not reach, as its backup says' do
    runtime = interpreter
    expect(mapping(customer(handling: 'Find', backup: 'Ignore'), runtime).import('{"code":"X"}')).to eq([])
    expect { mapping(customer(handling: 'Find', backup: 'Error'), runtime).import('{"code":"X"}') }
      .to raise_error(Mxrb::NativeRuntimeError, /found no Views.Customer/)
    created = mapping(customer(handling: 'Find', backup: 'Create'), runtime).import('{"code":"X"}')
    expect(created.map { _1.members['Code'] }).to eq(['X'])
    expect { mapping(customer(handling: 'Find', key: false), runtime).import('{"code":"X"}') }
      .to raise_error(Mxrb::NativeRuntimeError, /without a key/)
  end

  it 'adds to a reference set and refuses an unknown association' do
    runtime = interpreter
    root = customer(handling: 'Create').merge('entity' => 'Views.Order', 'children' => [])
    tag = customer(handling: 'Create').merge('path' => %w[(Object) tags (Wrapper)], 'entity' => 'Views.Tag',
                                             'association' => 'Views.Tag_Order', 'children' => [])
    root['children'] = [tag]
    set = { 'Views.Tag_Order' => { type: :ReferenceSet, from: 'Views.Tag' } }
    tags = mapping(root, runtime, associations: set).import('{"tags":["a","b"]}').first
    expect(runtime.store.retrieve('Views.Tag').map { _1.members['Tag_Order'] }).to all(eq([tags]))
    expect { mapping(root, runtime, associations: {}).import('{"tags":["a"]}') }
      .to raise_error(Mxrb::NativeRuntimeError, /unknown association Views.Tag_Order/)
  end

  it 'converts values through a converter and from text, numbers and epochs' do
    runtime = interpreter
    subject = mapping(customer(handling: 'Create'), runtime, converter: ->(_name, value) { value.upcase })
    subject.instance_variable_get(:@definition)['elements'].first['children'].first['converter'] = 'Views.Upper'
    expect(subject.import('{"code":"low"}').first.members['Code']).to eq('LOW')
    convert = ->(type, raw) { subject.send(:convert, type, raw) }
    expect([convert.call('Integer', '42'), convert.call('Long', 7.9),
            convert.call('Boolean', 'TRUE')]).to eq([42, 7, true])
    expect(convert.call('Enumeration', { 'a' => 1 })).to eq('{"a":1}')
    expect(convert.call('Binary', 'raw')).to eq('raw')
    expect(convert.call('DateTime', 0)).to eq(Time.at(0).utc)
    expect(convert.call('DateTime', '2024-05-01 10:15:30 UTC')).to eq(Time.utc(2024, 5, 1, 10, 15, 30))
  end

  it 'refuses XML content, unreadable JSON and a mapping the project lacks' do
    runtime = interpreter
    call = lambda { |type|
      { 'ImportMappingCall' => { 'ReturnValueMapping' => 'Views.ImportOrder', 'ContentType' => type } }
    }
    expect { runtime.send(:import_with_mapping, call.call('Xml'), '<a/>', {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /reads Xml; only JSON/)
    expect { runtime.send(:import_with_mapping, call.call('Json'), '{', {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /could not read the JSON/)
    missing = { 'ImportMappingCall' => { 'ReturnValueMapping' => 'Views.Nope', 'ContentType' => 'Json' } }
    expect { runtime.send(:import_with_mapping, missing, '{}', {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /Views.Nope not found/)
  end

  it 'applies the import mapping of a REST call, stored or not' do
    response = Struct.new(:code, :body).new('200', '{"name":"remote","tags":["a"]}')
    runtime = interpreter(http: ->(*) { response })
    call = { 'ReturnValueMapping' => 'Views.ImportOrder', 'ContentType' => 'Json' }
    action = lambda do |handling|
      {
        'HttpConfiguration' => { 'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => 'https://x.test' } },
        'RequestHandling' => {}, 'ResultHandling' => handling.merge('ImportMappingCall' => call)
      }
    end
    variables = {}
    runtime.send(:action_rest_call, action.call({ 'Bind' => true, 'ResultVariableName' => 'order' }), variables)
    expect(variables.fetch('order').members['Name']).to eq('remote')
    runtime.send(:action_rest_call, action.call({ 'Bind' => false }), variables)
    expect(runtime.store.retrieve('Views.Order').size).to eq(2)
    expect(variables.keys).to contain_exactly('order', 'latestHttpResponse')
  end

  it 'walks root arrays, nulls, single wrapped values and links without an association' do
    runtime = interpreter
    entry = customer(handling: 'Create').merge('path' => %w[(Array) (Object)])
    entry['children'].first['path'] = %w[(Array) (Object) code]
    stray = entry['children'].first.merge('path' => %w[(Array) code])
    root = customer(handling: 'Create').merge('path' => ['(Array)'], 'entity' => '', 'children' => [entry, stray])
    expect(mapping(root, runtime).import([{ 'code' => 'A' }, 'junk']).map { _1.members['Code'] }).to eq(['A'])
    expect(mapping(root, runtime).import('{"code":"B"}')).to eq([])
    expect(mapping(customer(handling: 'Create'), runtime).import('"text"')).to eq([])
    order = customer(handling: 'Create').merge('entity' => 'Views.Order', 'children' => [customer(handling: 'Create')])
    order['children'].first.merge!('path' => %w[(Object) customer])
    linked = mapping(order, runtime).import('{"customer":{}}').first
    expect(linked.members).not_to have_key('Order_Customer')
    definition = runtime.send(:import_mapping_definition, 'Views.ImportOrder')
    imported = described_class.new(definition, store: runtime.store,
                                               associations: runtime.instance_variable_get(:@associations))
    imported.import('{"name":"n","customer":null,"tags":"solo"}')
    expect(imported.objects.map(&:entity)).to eq(%w[Views.Order Views.Tag])
  end

  it 'binds a list of roots and runs converter microflows' do
    runtime = interpreter
    handling = {
      'Bind' => true, 'ResultVariableName' => 'orders', 'VariableType' => { '$Type' => 'DataTypes$ListType' },
      'ImportMappingCall' => { 'ReturnValueMapping' => 'Views.ImportOrder', 'ContentType' => 'Json' }
    }
    variables = {}
    runtime.send(:import_with_mapping, handling, '{"name":"one"}', variables)
    expect(variables.fetch('orders').map { _1.members['Name'] }).to eq(['one'])
    expect { runtime.send(:import_mapping_definition, 'Nope.Thing') }.to raise_error(Mxrb::NativeRuntimeError)
    expect { runtime.send(:convert_with_microflow, 'Views.Nope', 'x') }
      .to raise_error(Mxrb::NativeRuntimeError, /converter microflow Views.Nope not found/)
    expect(runtime.send(:convert_with_microflow, 'Views.ImportList', 'x')).to eq('empty')
  end

  it 'prefers a registered import adapter' do
    runtime = interpreter(adapters: { import_xml: ->(*) { 'adapted' } })
    variables = {}
    runtime.send(:action_import_xml, { 'ImportMapping' => 'Views.ImportOrder',
                                       'ResultHandling' => { 'ResultVariableName' => 'out' } }, variables)
    expect(variables['out']).to eq('adapted')
  end
end
# rubocop:enable Metrics/BlockLength
