# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/AbcSize
RSpec.describe 'method-oriented flow sources' do
  def builder
    Mxrb::Dsl::FlowBuilder.new(:Example, runtime: :server, kind: :use_case, public: false)
  end

  def compose(source, captions: {})
    methods = Mxrb::Exporter::MethodFlowSource.new(source, captions:).source
    plan = Class.new(Mxrb::Dsl::FlowProgram)
    plan.class_eval(methods, 'generated_flow.rb', 1)
    [plan, methods]
  end

  it 'keeps the complete typed body while exposing decision, merge continuation and named activities' do
    source = <<~RUBY
      parameter :Flag, type: :Boolean
      create_variable :Result, type: :Integer, value: '0'
      decision '$Flag' do
        on true do
          change_variable :Result, to: '1'
        end
        on false do
          change_variable :Result, to: '2'
        end
      end
      change_variable :Result, to: '$Result + 10'
      return_value '$Result'
    RUBY
    plan, methods = compose(source)
    original = builder
    original.instance_eval(source)
    generated = builder
    plan.build(generated)
    expect(generated.to_h).to eq(original.to_h)
    expect(methods).to include('def main_line', 'decide', 'if_true: :change_variable_result')
    expect(methods).not_to include(' do')
    main_line = methods.split("\nprivate").first
    expect(main_line).not_to include('parameter')
    expect(main_line.index('decide')).to be < main_line.index('change_variable_result_3')
  end

  it 'supports Proc and block steps with isolated nested builder scope, including loop controls and errors' do
    plan = Class.new(Mxrb::Dsl::FlowProgram) do
      def main_line
        create_variable :Count, value: '0'
        while_loop '$Count < 3', &step(:iteration)
        call_microflow 'App.Missing'
        rescue_all rollback: true, &step { return_value '-1' }
      end

      def iteration
        change_variable :Count, to: '$Count + 1'
        decide '$Count = 2', branches: { true => proc { continue_loop }, false => :advance }
      end

      def advance
        change_variable :Count, to: '$Count + 0'
      end
    end
    generated = builder
    plan.build(generated)
    original = builder
    original.instance_eval do
      create_variable :Count, value: '0'
      while_loop '$Count < 3' do
        change_variable :Count, to: '$Count + 1'
        decision '$Count = 2' do
          on(true) { continue_loop }
          on(false) { change_variable :Count, to: '$Count + 0' }
        end
      end
      call_microflow 'App.Missing'
      rescue_all(rollback: true) { return_value '-1' }
    end
    expect(generated.to_h).to eq(original.to_h)
    expect { generated.break_loop }.to raise_error(ArgumentError, /inside a loop/)
    results = Array.new(8) do
      Thread.new do
        target = builder
        plan.build(target)
        target.to_h
      end
    end.map(&:value)
    expect(results).to all(eq(original.to_h))
  end

  it 'preserves rule arguments, inheritance branches and non-ASCII member blocks without evaluating expressions' do
    source = <<~RUBY
      create_object 'App.Item', as: :Item do
        set :Name, to: "'ação'"
      end
      rule_decision 'App.Check' do
        argument 'App.Check.Value', "'ação'"
        argument 'App.Check.Value', "'outro'"
        on(true) do
          type_decision :Item do
            on_type 'App.SpecialItem' do
              cast :Item
            end
            otherwise do
              return_value 'empty'
            end
          end
        end
        on(false) do
          return_value 'empty'
        end
      end
    RUBY
    plan, methods = compose(source)
    generated = builder
    plan.build(generated)
    original = builder
    original.instance_eval(source)
    expect(generated.to_h).to eq(original.to_h)
    expect(methods).to include('rule_decision', 'argument', 'type_decision', 'ação')
  end

  it 'uses activity captions with safe deterministic names and resolves all collisions' do
    source = <<~RUBY
      create_variable :First, value: '1'
      create_variable :Second, value: '2'
      create_variable :Third, value: '3'
      create_variable :Fourth, value: '4'
      create_variable :Fifth, value: '5'
    RUBY
    names = ['Aprovar pedido', 'Aprovar pedido', 'aprovar_pedido_2', 'initialize', 'Create variable']
    captions = source.lines.zip(names)
                     .to_h { |line, caption| [Mxrb::Exporter::MethodFlowSource.normalize(line), [caption]] }
    _plan, methods = compose(source, captions:)
    expect(methods).to include('def aprovar_pedido', 'def aprovar_pedido_2', 'def aprovar_pedido_2_2',
                               'def activity_initialize', 'def create_variable_fifth')
    expect(compose(source, captions:).last).to eq(methods)
  end

  it 'uses typed case options without leaking hash literals into generated public source' do
    source = <<~RUBY
      decision '$State' do
        on 'ready' do
          call_microflow 'App.Process'
        end
        on 'new' do
          return_value '-1'
        end
      end
    RUBY
    plan, methods = compose(source)
    generated = builder
    plan.build(generated)
    original = builder
    original.instance_eval(source)
    expect(generated.to_h).to eq(original.to_h)
    expect(methods).to include('cases: [[', '-> { return_value')
    expect(methods).not_to include('=>', 'branches: {')
  end

  it 'keeps legacy flow blocks and the public service call API working' do
    legacy = Class.new(Mxrb::RubyApp::Service)
    legacy.mendix_name 'Compatibility.Flow'
    legacy.flow(:microflow) do
      parameter :Input, type: :Integer
      return_type :Integer
      call microflow: 'Compatibility.Other'
      create_variable :Result, type: :Integer, value: '$Input + 1'
      return_value '$Result'
    end
    expected = legacy.native_definition
    Mxrb::RubyApp::Registry.reset!
    modern = Class.new(Mxrb::RubyApp::Service) do
      def main_line
        calculate_result
        return_value '$Result'
      end

      def flow_contract
        parameter :Input, type: :Integer
        return_type :Integer
        call microflow: 'Compatibility.Other'
      end

      def calculate_result
        create_variable :Result, type: :Integer, value: '$Input + 1'
      end
    end
    modern.mendix_name 'Compatibility.Flow'
    modern.flow(:microflow, main: :main_line)
    expect(modern.native_definition).to eq(expected)
    application = double(:application)
    expect(application).to receive(:native_call).with('Compatibility.Flow', { Input: 2 }, context: nil).and_return(3)
    expect(modern.new(application).call(Input: 2)).to eq(3)
    expect { modern.flow(:microflow, main: :main_line) {} }.to raise_error(ArgumentError, /not both/)
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  it 'round-trips both export modes with exact native IDs, layout and control-flow behavior' do
    Dir.mktmpdir('mxrb-method-flow-') do |directory|
      application = nil
      original = File.join(directory, 'Original.mpr')
      define_project(original)
      expected_documents = flow_documents(original)
      expected = execute(original)
      expect(expected).to include([true, false] => 110, [false, false] => 111, [true, true] => -7,
                                  recovered: -9, cycles: 4)
      %i[mendix ruby].each do |mode|
        exported = File.join(directory, mode.to_s)
        rebuilt = File.join(directory, "#{mode}.mpr")
        Mxrb::Exporter.new(original, exported, mode:).export!(parallel: false)
        sources = Dir.glob(File.join(exported, mode == :ruby ? 'app/services' : 'modules', '**', '*.rb'))
                     .map { File.read(_1) }.join
        expect(sources).to include('def main_line', 'decide')
        expect(sources).to include('def initialize_total')
        if mode == :ruby
          expect(Mxrb::PublicSourceAudit.new(exported)).to be_clean
          application = Mxrb::RubyApp::Application.new(exported)
          expect(application.call_service('App.Calculate', { 'Flag' => true, 'Early' => false })).to eq(110)
          application.close
          Mxrb::RubyApp.compile(exported, rebuilt)
        else
          previous = ENV['MXRB_OUTPUT_PATH']
          ENV['MXRB_OUTPUT_PATH'] = rebuilt
          load File.join(exported, 'project.rb')
          previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
        end
        expect(flow_documents(rebuilt)).to eq(expected_documents)
        expect(execute(rebuilt)).to eq(expected)
        next unless mode == :ruby

        services = Dir.glob(File.join(exported, 'app/services/**/*.rb'))
        file = services.find { File.read(_1).include?('$Adjusted + 100') }
        File.write(file, File.read(file).sub('$Adjusted + 100', '$Adjusted + 200'))
        edited = Mxrb::RubyApp.compile(exported, File.join(directory, 'Edited.mpr'))
        expect(execute(edited)).to include([true, false] => 210, [false, false] => 211, [true, true] => -7)
        expect(flow_documents(edited).keys).to match_array(expected_documents.keys)
      end
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def define_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        microflow(:Adjust) do
          parameter :Value, type: :Integer
          return_type :Integer
          return_value '$Value + 5'
        end
        microflow(:Calculate) do
          parameter :Flag, type: :Boolean
          parameter :Early, type: :Boolean
          return_type :Integer
          create_variable :Result, type: :Integer, value: '0'
          decision '$Flag' do
            on(true) { change_variable :Result, to: '2' }
            on(false) { change_variable :Result, to: '3' }
          end
          decision '$Early' do
            on(true) { return_value '-7' }
            on(false) { change_variable :Result, to: '$Result' }
          end
          create_variable :Index, type: :Integer, value: '0'
          while_loop '$Index < 3' do
            change_variable :Result, to: '$Result + $Index'
            change_variable :Index, to: '$Index + 1'
          end
          call_microflow 'App.Adjust', as: :Adjusted, pass: { 'App.Adjust.Value' => '$Result' }
          change_variable :Result, to: '$Adjusted + 100'
          return_value '$Result'
        end
        nanoflow(:Client) do
          return_type :Integer
          create_variable :Result, type: :Integer, value: '8'
          return_value '$Result'
        end
        microflow(:Boom) do
          return_type :Integer
          create_variable :Result, type: :Integer, value: '1 div 0'
          return_value '$Result'
        end
        microflow(:Recover) do
          return_type :Integer
          call_microflow 'App.Boom'
          rescue_all(rollback: true) { return_value '-9' }
          return_value '42'
        end
        microflow(:Cycles) do
          return_type :Integer
          create_variable :Index, type: :Integer, value: '0'
          create_variable :Total, type: :Integer, value: '0'
          while_loop '$Index < 5' do
            change_variable :Index, to: '$Index + 1'
            decision '$Index = 2' do
              on(true) { continue_loop }
              on(false) { change_variable :Total, to: '$Total' }
            end
            decision '$Index = 4' do
              on(true) { break_loop }
              on(false) { change_variable :Total, to: '$Total + $Index' }
            end
          end
          return_value '$Total'
        end
      end
    end
    Mxrb.open(path, readonly: false) do |project|
      flow = project.modules.first.microflows.find { _1.name == 'Calculate' }
      unit = project.mpr.unit(flow.id)
      document = project.mpr.parse_contents(unit)
      objects = Mxrb::IO::BsonCodec.parse_array(document.dig('ObjectCollection', 'Objects'))[:items]
      activity = objects.find { _1.dig('Action', '$Type') == 'Microflows$CreateVariableAction' }
      activity['Caption'] = 'Initialize total'
      activity['AutoGenerateCaption'] = false
      project.mpr.update_unit(flow.id, document)
    end
  end

  def execute(path)
    Mxrb.open(path) do |project|
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      values = [[true, false], [false, false], [true, true]].to_h do |flag, early|
        [[flag, early], interpreter.call('App.Calculate', { 'Flag' => flag, 'Early' => early })]
      end
      values.merge(recovered: interpreter.call('App.Recover'), cycles: interpreter.call('App.Cycles'))
    end
  end

  def flow_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [Mxrb::IO::BsonCodec.extract_id(document['$ID']), document] \
          if %w[Microflows$Microflow Microflows$Nanoflow Microflows$Rule].include?(document['$Type'])
      end.to_h
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/AbcSize
