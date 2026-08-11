# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Java Custom Action Ruby adapters' do
  def build_project(path)
    parameter_id = '11111111-1111-4111-8111-111111111111'
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Actions do
        native_document :Normalize, type: 'JavaActions$JavaAction', deep_structure: {
          'Parameters' => Mxrb::IO::BsonCodec.build_array([
                                                            {
                                                              '$ID' => parameter_id,
                                                              '$Type' => 'JavaActions$JavaActionParameter',
                                                              'Name' => 'Input',
                                                              'ParameterType' => {
                                                                '$Type' => 'CodeActions$BasicParameterType',
                                                                'Type' => { '$Type' => 'CodeActions$StringType' }
                                                              }
                                                            }
                                                          ]),
          'JavaReturnType' => { '$Type' => 'CodeActions$StringType' }
        }
        microflow :Invoke do
          parameter :Source, type: :String
          return_type :String
          call_java 'Actions.Normalize', as: :normalized, pass: {
            parameter_id => '$Source',
            :Entity => { kind: :entity, value: 'Actions.Item' },
            :Callback => { kind: :microflow, value: 'Actions.Helper' },
            :Reader => { kind: :import_mapping, value: 'Actions.Reader' },
            :Writer => { kind: :export_mapping, value: 'Actions.Writer' }
          }
          return_value '$normalized'
        end
      end
    end
  end

  it 'maps Mendix parameter values and assigns the registered adapter result' do
    Dir.mktmpdir('mxrb-java-action-') do |root|
      path = File.join(root, 'Actions.mpr')
      build_project(path)
      project = Mxrb::Model::Project.open(path)
      received = nil
      adapter = lambda do |arguments|
        received = arguments
        arguments.fetch('Input').upcase
      end
      interpreter = Mxrb::Runtime::Native::Interpreter.new(
        project, java_custom_actions: { 'Actions.Normalize' => adapter }
      )

      expect(interpreter.call('Actions.Invoke', 'Source' => 'ruby')).to eq('RUBY')
      expect(received).to eq(
        'Input' => 'ruby', 'Entity' => 'Actions.Item', 'Callback' => 'Actions.Helper',
        'Reader' => 'Actions.Reader', 'Writer' => 'Actions.Writer'
      )
      expect(received).to be_frozen
    ensure
      project&.close
    end
  end

  it 'fails closed when no qualified adapter was registered' do
    Dir.mktmpdir('mxrb-java-action-') do |root|
      path = File.join(root, 'Actions.mpr')
      build_project(path)
      project = Mxrb::Model::Project.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)

      expect { interpreter.call('Actions.Invoke', 'Source' => 'ruby') }
        .to raise_error(
          Mxrb::NativeRuntimeError,
          /Java Custom Action Actions\.Normalize is not registered.*register_java_custom_action/
        )
    ensure
      project&.close
    end
  end

  it 'registers only callable adapters under qualified names' do
    registry = Mxrb::RubyApp::Registry
    registry.reset!
    callback = ->(arguments) { arguments }

    expect(registry.register_java_custom_action('Actions.Normalize', callback)).to equal(callback)
    expect(registry.java_custom_actions).to eq('Actions.Normalize' => callback)
    expect { registry.register_java_custom_action('Normalize', callback) }
      .to raise_error(ArgumentError, /qualified as Module\.Action/)
    expect { registry.register_java_custom_action('Actions.Other', Object.new) }
      .to raise_error(ArgumentError, /must respond to call/)
  ensure
    registry.reset!
  end

  it 'supports OutputVariableName and respects an explicit UseReturnVariable false' do
    project = double(find_artifact: nil)
    adapter = ->(_arguments) { 'result' }
    interpreter = Mxrb::Runtime::Native::Interpreter.allocate
    interpreter.instance_variable_set(:@project, project)
    interpreter.instance_variable_set(:@expression, Mxrb::Runtime::Native::Expression.new)
    interpreter.instance_variable_set(:@identifier_cache, {}.compare_by_identity)
    interpreter.instance_variable_set(:@java_action_parameter_names, {})
    interpreter.instance_variable_set(:@java_custom_actions, 'Actions.Normalize' => adapter)
    variables = {}
    action = {
      'JavaAction' => 'Actions.Normalize', 'ParameterMappings' => [],
      'OutputVariableName' => 'Output', 'UseReturnVariable' => true
    }

    expect(interpreter.send(:action_java_action_call, action, variables)).to eq('result')
    expect(variables).to eq('Output' => 'result')
    action['UseReturnVariable'] = false
    variables.clear
    interpreter.send(:action_java_action_call, action, variables)
    expect(variables).to be_empty
  end

  it 'supports legacy return variables and rejects malformed parameter mappings' do
    project = double(find_artifact: nil)
    interpreter = Mxrb::Runtime::Native::Interpreter.allocate
    interpreter.instance_variable_set(:@project, project)
    interpreter.instance_variable_set(:@expression, Mxrb::Runtime::Native::Expression.new)
    interpreter.instance_variable_set(:@identifier_cache, {}.compare_by_identity)
    interpreter.instance_variable_set(:@java_action_parameter_names, {})
    interpreter.instance_variable_set(
      :@java_custom_actions, 'Actions.Normalize' => ->(_arguments) { 'legacy-result' }
    )

    variables = {}
    legacy = {
      'JavaAction' => 'Actions.Normalize', 'ParameterMappings' => [],
      'ResultVariableName' => 'LegacyResult'
    }
    expect(interpreter.send(:action_java_action_call, legacy, variables)).to eq('legacy-result')
    expect(variables).to eq('LegacyResult' => 'legacy-result')

    unnamed = {
      'JavaAction' => 'Actions.Normalize',
      'ParameterMappings' => [{ 'Parameter' => '', 'Value' => {} }]
    }
    expect { interpreter.send(:action_java_action_call, unnamed, {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /unnamed parameter mapping/)

    unsupported = {
      'JavaAction' => 'Actions.Normalize',
      'ParameterMappings' => [{
        'Parameter' => 'Unsupported',
        'Value' => { '$Type' => 'Microflows$UnsupportedJavaActionParameterValue' }
      }]
    }
    expect { interpreter.send(:action_java_action_call, unsupported, {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /uses unsupported mapping/)

    interpreter.instance_variable_set(:@java_custom_actions, {})
    expect { interpreter.send(:action_java_action_call, { 'JavaAction' => '' }, {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /\(missing name\) is not registered/)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
