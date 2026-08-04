# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::NanoflowProgramCompiler do
  def build_source # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir do |root|
      path = File.join(root, 'Nanoflows.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          nanoflow(:Child) { return_value 'true' }
          nanoflow(:Load) do
            create_variable :ready, type: :boolean, value: 'true'
            call_nanoflow 'Demo.Child', as: :child_result
            return_value '$ready'
          end
        end
      end
      yield Mxrb::Compiler::SourceModel.read(path)
    end
  end

  it 'compiles ordered client instructions and nested nanoflow references' do
    build_source do |source|
      compiler = described_class.new(source)
      reference = compiler.reference('Demo.Load')
      output = compiler.declarations

      expect(reference).to match(/\A\(\) => mxrbNanoflow_[a-f0-9]{12}\z/)
      expect(output).to include(
        '"name": "Demo.Load"', '"type": "setVariable"',
        '"type": "nanoflowCall"', '"flow": () => mxrbNanoflow_',
        '"type": "return"', '"variable": "ready"', '"name": "Demo.Child"'
      )
      expect(compiler.reference('Demo.Load')).to eq(reference)
      expect(compiler.unsupported).to be_empty
    end
  end

  it 'fails closed for a missing flow or unsupported client instruction' do
    build_source do |source|
      compiler = described_class.new(source)
      expect(compiler.reference('Demo.Missing')).to be_nil

      flow = source.units_of('Microflows$Nanoflow').find { _1.document['Name'] == 'Load' }
      activity = flow.document.dig('ObjectCollection', 'Objects').find do |item|
        item.is_a?(Hash) && item['$Type'] == 'Microflows$ActionActivity'
      end
      activity['Action']['$Type'] = 'Microflows$UnsupportedClientAction'
      expect(compiler.reference('Demo.Load')).to be_nil
      expect(compiler.unsupported).to include(/UnsupportedClientAction/)
    end
  end

  it 'covers safe instruction and expression variants used by the client schema' do
    build_source do |source|
      compiler = described_class.new(source)
      id = { '$ID' => '11111111-1111-4111-8111-111111111111' }
      expect(compiler.send(:compile_node, '$Type' => 'Microflows$Annotation')).to be_nil
      create = id.merge(
        '$Type' => 'Microflows$ActionActivity',
        'Action' => id.merge('$Type' => 'Microflows$CreateObjectAction',
                             'Entity' => 'Demo.Item', 'VariableName' => 'Item')
      )
      expect(compiler.send(:compile_node, create)).to include(
        include(type: 'createObject', objectType: 'Demo.Item', outputVar: 'Item')
      )
      call = id.merge(
        '$Type' => 'Microflows$NanoflowCallAction', 'OutputVariableName' => '',
        'NanoflowCall' => { 'Nanoflow' => 'Demo.Child', 'ParameterMappings' => [
          2, nil, { 'Parameter' => 'Demo.Child.Input', 'Argument' => '42' }
        ] }
      )
      expect(compiler.send(:compile_nanoflow_call, call)).to include(
        parameters: [include(name: 'Input', kind: 'primitive')]
      )
      missing = id.merge(
        '$Type' => 'Microflows$NanoflowCallAction',
        'NanoflowCall' => { 'Nanoflow' => 'Demo.Missing' }
      )
      expect(compiler.send(:compile_nanoflow_call, missing)).to be_nil

      expressions = ['', 'empty', '$Item', 'true', 'false', "'text'", '"text"', '-12.5', '@Constant']
      expect(expressions.map { compiler.send(:expression, _1) }).to include(
        { type: 'literal', value: nil }, { type: 'variable', variable: 'Item' },
        { type: 'literal', value: false }, { type: 'literalNumeric', value: '-12.5' },
        { type: 'constant', name: 'Constant' }
      )
      compiler.instance_variable_get(:@programs)['Demo.Nil'] = nil
      expect(compiler.reference('Demo.Nil')).to be_nil
      compiler.send(:unsupported!, { '$Type' => 'Microflows$EmptyAction' }, '')
      expect(compiler.unsupported.last).to end_with(':Microflows$EmptyAction')
    end
  end

  it 'compiles decisions as explicit switch control flow' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'Branching.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          nanoflow(:Branch) do
            decision '$ready' do
              on(true)  { return_value 'true' }
              on(false) { return_value 'false' }
            end
          end
        end
      end
      compiler = described_class.new(Mxrb::Compiler::SourceModel.read(path))

      expect(compiler.reference('Demo.Branch')).to match(/mxrbNanoflow/)
      expect(compiler.declarations).to include(
        '"type": "switch"', '"targets": { "true":', '"false":'
      )
      expect(compiler.unsupported).to be_empty
    end
  end

  it 'covers defensive graph, action, parameter, and expression decisions' do # rubocop:disable Metrics/BlockLength
    build_source do |source|
      compiler = described_class.new(source)
      id = ->(suffix) { { '$ID' => "11111111-1111-4111-8111-#{suffix.to_s.rjust(12, '0')}" } }
      node = id.call(1).merge('$Type' => 'Microflows$ActionActivity')

      expect(compiler.send(:reachable_nodes, nil, {}, {})).to eq([])
      expect(compiler.send(:reachable_nodes, id.call(2), {}, id.call(2)['$ID'] => [{
        'DestinationPointer' => id.call(99)
      }])).to eq([])
      expect(compiler.send(:compile_graph_node, node.merge('Action' => {
        '$Type' => 'Microflows$CreateVariableAction', 'VariableName' => 'x'
      }), [])).to contain_exactly(include(type: 'setVariable'))
      expect(compiler.send(:compile_graph_node, node.merge('$Type' => 'Microflows$EndEvent'), []))
        .to contain_exactly(include(type: 'return'))
      expect(compiler.send(:compile_try_catch, node, [], [])).to be_nil
      normal = { 'DestinationPointer' => id.call(8) }
      error = { 'IsErrorHandler' => true, 'DestinationPointer' => id.call(9) }
      expect(compiler.send(:compile_try_catch, node.merge('Action' => {
        '$Type' => 'Microflows$CreateObjectAction', 'Entity' => 'Demo.Item', 'VariableName' => 'Item'
      }), [normal], [error])).to include(type: 'tryCatch', body: be_an(Array))
      expect(compiler.send(:compile_try_catch, node.merge('Action' => {
        '$Type' => 'Microflows$Unsupported'
      }), [normal], [error])).to be_nil

      create = {
        '$Type' => 'Microflows$CreateObjectAction', 'Entity' => 'Demo.Item',
        'VariableName' => 'Item', 'Commit' => 'Yes', 'Items' => [2, {
          '$Type' => 'Microflows$MemberChange', 'Attribute' => 'Demo.Item.Name',
          'Type' => 'Set', 'Value' => "'Name'"
        }]
      }
      expect(compiler.send(:compile_create_object, create, node)).to include(include(type: 'commitObjects'))
      expect(compiler.send(:compile_node, node.merge('Action' => {
        '$Type' => 'Microflows$CommitAction', 'CommitVariableName' => 'Item'
      }))).to include(type: 'commitObjects')
      expect(compiler.send(:change_instructions, { 'Items' => [2, {
        '$Type' => 'Bad', 'Attribute' => '', 'Type' => 'Add'
      }] }, 'Item', 'change')).to be_empty
      expect(compiler.send(:compile_microflow_call, { '$Type' => 'Call', 'MicroflowCall' => {} }, node)).to be_nil
      expect(compiler.send(:compile_javascript_call, {
        '$Type' => 'JavaScript', 'JavaScriptAction' => 'Demo.Missing'
      }, node)).to be_nil

      expect(compiler.send(:quoted_entity, 'Demo.Item')).to eq('"Demo.Item"')
      expect(compiler.send(:quoted_entity, '')).to be_nil
      expect(compiler.send(:javascript_parameter_kind, {
        'ParameterType' => { 'Type' => { '$Type' => 'DataTypes$EntityType' } }
      })).to eq('object')
      expect(compiler.send(:javascript_parameter_kind, {
        'ParameterType' => { 'Type' => { '$Type' => 'DataTypes$ListType' } }
      })).to eq('list')

      no_case = { '$Type' => 'Microflows$NoCase' }
      expect(compiler.send(:compile_split, id.call(3).merge(
                                             'SplitCondition' => { 'Expression' => '$ready' }
                                           ), [{ 'CaseValues' => [2, no_case], 'DestinationPointer' => id.call(4) }]))
        .to include(targets: { '' => id.call(4)['$ID'] })
      expect(compiler.send(:compile_split, id.call(3), [])).to be_nil
      expect(compiler.send(:compile_split, id.call(3).merge(
                                             'SplitCondition' => { 'Expression' => '$ready' }
                                           ), [{ 'CaseValues' => [2], 'DestinationPointer' => id.call(4) }]))
        .to include(targets: include(''))
      expect(compiler.send(:compile_merge, id.call(3), [])).to be_nil
      expect(compiler.send(:compile_show_form, { '$Type' => 'Show', 'FormSettings' => {} }, node)).to be_nil
      expect(compiler.send(:compile_validation, { '$Type' => 'Validation', 'Attribute' => '' }, node)).to be_nil
      expect(compiler.send(:compile_commit, { '$Type' => 'Commit' }, node)).to be_nil
      expect(compiler.send(:compile_commit, { 'CommitVariableName' => 'Item' }, node, label: false))
        .not_to have_key(:label)

      expect(compiler.send(:text_template_expression, nil)).to eq(type: 'literal', value: nil)
      localized = { 'Text' => { 'Items' => [2, { 'LanguageCode' => 'pt_BR', 'Text' => 'Oi' }] },
                    'Parameters' => [2, { 'Expression' => '$Name' }] }
      expect(compiler.send(:text_template_expression, localized)).to include(type: 'function')
      expect(compiler.send(:variable_kind, '$Type' => 'DataTypes$ObjectType')).to eq('object')
      expect(compiler.send(:variable_kind, nil)).to eq('primitive')

      ['not($ready)', 'isNew($Item)', '$a and $b', '$a = $b', 'if true then 1 else 2'].each do |expression|
        expect(compiler.send(:expression, expression)).to be_a(Hash)
      end
      expect(compiler.send(:current_variable_kinds)).to eq({})
      compiler.instance_variable_set(:@variable_kind_stack, [{ 'Item' => 'object' }])
      expect(compiler.send(:expression_kind, '$Item')).to eq('object')
      expect(compiler.send(:function_expression, 'unknown()')).to be_nil
      expect(compiler.send(:binary_expression, 'plain')).to be_nil
      expect(compiler.send(:conditional_expression, 'plain')).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
