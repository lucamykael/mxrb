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

  it 'covers every supported action and defensive compiler branch' do
    build_source do |source|
      compiler = described_class.new(source)
      identifier = lambda do |suffix|
        { '$ID' => "22222222-2222-4222-8222-#{suffix.to_s.rjust(12, '0')}" }
      end
      node = identifier.call(1).merge('$Type' => 'Microflows$ActionActivity')
      action_node = ->(action) { node.merge('Action' => action) }

      parameter = {
        '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Input',
        'VariableType' => { '$Type' => 'DataTypes$ObjectType' }
      }
      create_change = {
        '$Type' => 'Microflows$ActionActivity',
        'Action' => {
          '$Type' => 'Microflows$CreateChangeAction', 'VariableName' => 'Created',
          'VariableType' => { '$Type' => 'DataTypes$StringType' },
          'OutputVariableName' => 'Output', 'ResultVariableName' => 'Result'
        }
      }
      kinds = compiler.send(
        :variable_kinds, 'ObjectCollection' => { 'Objects' => [2, parameter, create_change] }
      )
      expect(kinds).to include(
        'Input' => 'object', 'Created' => 'object', 'Output' => 'object',
        'Result' => 'primitive'
      )

      start = identifier.call(2)
      repeated = identifier.call(3).merge('$Type' => 'Microflows$EndEvent')
      flows = {
        start['$ID'] => [
          { 'DestinationPointer' => repeated['$ID'] },
          { 'DestinationPointer' => repeated['$ID'] }
        ]
      }
      expect(compiler.send(:reachable_nodes, start, { repeated['$ID'] => repeated }, flows))
        .to eq([repeated])

      normal = { 'DestinationPointer' => identifier.call(4) }
      error = { 'IsErrorHandler' => true, 'DestinationPointer' => identifier.call(5) }
      protected_node = action_node.call(
        '$Type' => 'Microflows$CreateVariableAction', 'VariableName' => 'Protected',
        'VariableType' => { '$Type' => 'DataTypes$BooleanType' }, 'InitialValue' => 'true'
      )
      expect(compiler.send(:compile_graph_node, protected_node, [normal, error]))
        .to include(include(type: 'tryCatch'), include(type: 'jump'))
      array_node = action_node.call(
        '$Type' => 'Microflows$CreateObjectAction', 'Entity' => 'Demo.Item',
        'VariableName' => 'Created'
      )
      expect(compiler.send(:compile_graph_node, array_node, [normal]))
        .to include(include(type: 'createObject'), include(type: 'jump'))
      merge = identifier.call(6).merge('$Type' => 'Microflows$ExclusiveMerge')
      expect(compiler.send(:compile_node, merge, [normal])).to include(type: 'jump')

      expect(compiler.send(:compile_node, action_node.call(
                                            '$Type' => 'Microflows$ChangeVariableAction',
                                            'ChangeVariableName' => 'Ready', 'Value' => 'false'
                                          ))).to include(type: 'setVariable', outputVar: 'Ready')
      expect(compiler.send(:compile_node, action_node.call(
                                            '$Type' => 'Microflows$CreateChangeAction',
                                            'Entity' => 'Demo.Item', 'VariableName' => 'Created'
                                          ))).to include(include(type: 'createObject'))

      changes = [2,
                 { '$Type' => 'Microflows$MemberChange', 'Attribute' => 'Demo.Item.Name',
                   'Type' => 'Set', 'Value' => "'First'" },
                 { '$Type' => 'Microflows$MemberChange', 'Attribute' => 'Demo.Item.Code',
                   'Type' => 'Set', 'Value' => "'Second'" }]
      change_action = {
        '$Type' => 'Microflows$ChangeAction', 'ChangeVariableName' => 'Item',
        'Items' => changes, 'Commit' => 'Yes'
      }
      compiled_changes = compiler.send(:compile_node, action_node.call(change_action))
      expect(compiled_changes).to include(
        include(type: 'changeObject', member: 'Name'),
        include(type: 'changeObject', member: 'Code'), include(type: 'commitObjects')
      )
      expect(compiler.send(:compile_change_object, change_action.merge('Commit' => 'No'), node))
        .not_to include(include(type: 'commitObjects'))

      microflow_call = {
        '$Type' => 'Microflows$MicroflowCallAction', 'UseReturnVariable' => true,
        'ResultVariableName' => 'Called',
        'MicroflowCall' => { 'Microflow' => 'Demo.Server', 'ParameterMappings' => [2] }
      }
      expect(compiler.send(:compile_node, action_node.call(microflow_call)))
        .to include(type: 'microflowCall', outputVar: 'Called')
      expect(compiler.send(:compile_microflow_call,
                           microflow_call.merge('UseReturnVariable' => false), node))
        .not_to have_key(:outputVar)

      javascript_unit = Mxrb::Compiler::SourceModel::Unit.new(
        id: 'js', container_id: 'module', containment: 'Documents', module_name: 'Demo',
        document: {
          '$Type' => 'JavaScriptActions$JavaScriptAction', 'Name' => 'Notify',
          'Parameters' => [2,
                           { 'Name' => 'Item', 'ParameterType' => {
                             'Type' => { '$Type' => 'DataTypes$EntityType' }
                           } },
                           { 'Name' => 'Items', 'ParameterType' => {
                             'Type' => { '$Type' => 'DataTypes$ListType' }
                           } },
                           { 'Name' => 'Count', 'ParameterType' => {
                             'Type' => { '$Type' => 'DataTypes$IntegerType' }
                           } }]
        }
      )
      allow(source).to receive(:units_of).and_wrap_original do |original, type|
        type == 'JavaScriptActions$JavaScriptAction' ? [javascript_unit] : original.call(type)
      end
      javascript_call = {
        '$Type' => 'Microflows$JavaScriptActionCallAction',
        'JavaScriptAction' => 'Demo.Notify', 'UseReturnVariable' => true,
        'OutputVariableName' => 'Notification',
        'ParameterMappings' => [2,
                                { 'Parameter' => 'Demo.Notify.Item',
                                  'ParameterValue' => { 'Argument' => '$Item' } },
                                { 'Parameter' => 'Demo.Notify.Items',
                                  'ParameterValue' => { 'Entity' => 'Demo.Item' } },
                                { 'Parameter' => 'Demo.Notify.Count',
                                  'ParameterValue' => { 'Argument' => '2' } }]
      }
      compiled_javascript = compiler.send(:compile_node, action_node.call(javascript_call))
      expect(compiled_javascript).to include(
        type: 'javaScriptActionCall', outputVar: 'Notification',
        parameters: [include(kind: 'object'), include(kind: 'list'), include(kind: 'primitive')]
      )
      expect(compiler.send(:compile_javascript_call,
                           javascript_call.merge('UseReturnVariable' => false), node))
        .not_to have_key(:outputVar)
      expect(compiler.send(:javascript_reference, javascript_unit))
        .to include('javascriptsource/demo/actions/Notify')

      form_action = {
        '$Type' => 'Microflows$ShowFormAction',
        'FormSettings' => {
          'Form' => 'Demo.Detail', 'ParameterMappings' => [2, {
            'Parameter' => 'Demo.Detail.Item', 'Argument' => '$Item'
          }]
        }
      }
      expect(compiler.send(:compile_node, action_node.call(form_action)))
        .to include(type: 'openForm', inputArgs: include('$Item'))
      expect(compiler.send(:compile_show_form,
                           form_action.merge('FormSettings' => { 'Form' => 'Demo.Detail' }), node))
        .not_to have_key(:inputArgs)

      close = { '$Type' => 'Microflows$CloseFormAction', 'NumberOfPagesToClose' => '2' }
      expect(compiler.send(:compile_node, action_node.call(close)))
        .to include(type: 'closeForm', numberOfPagesToClose: include(value: '2'))
      expect(compiler.send(:compile_close_form, close.merge('NumberOfPagesToClose' => ''), node))
        .not_to have_key(:numberOfPagesToClose)
      expect(compiler.send(:compile_node, action_node.call(
                                            '$Type' => 'Microflows$ShowMessageAction', 'Type' => 'Warning',
                                            'Blocking' => true, 'Template' => { 'Text' => 'Attention' }
                                          ))).to include(type: 'showMessage', blocking: true)
      expect(compiler.send(:compile_node, action_node.call(
                                            '$Type' => 'Microflows$ValidationFeedbackAction',
                                            'Attribute' => 'Demo.Item.Name',
                                            'ValidationVariableName' => 'Item',
                                            'FeedbackTemplate' => { 'Text' => 'Required' }
                                          ))).to include(type: 'showValidation', member: 'Name')
      expect(compiler.send(:compile_node, action_node.call(
                                            '$Type' => 'Microflows$LogMessageAction', 'Level' => 'Info',
                                            'MessageTemplate' => { 'Text' => 'Saved' }
                                          ))).to include(type: 'writeLog', level: 'info')

      localized = {
        'Text' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Hello' }] }
      }
      expect(compiler.send(:text_template_expression, localized)).to include(value: 'Hello')
      expect(compiler.send(:text_template_expression, 'Text' => { 'Items' => [2] }))
        .to eq(type: 'literal', value: nil)
      expect(compiler.send(:expression, '$Item/Name')).to include(path: 'Name')
      expect(compiler.send(:expression, 'plain text')).to eq(type: 'literal', value: 'plain text')
    end
  end
end
# rubocop:enable Metrics/BlockLength
