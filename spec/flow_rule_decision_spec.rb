# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'typed rule decisions' do # rubocop:disable Metrics/BlockLength
  def builder
    Mxrb::Dsl::FlowBuilder.new(:Check, runtime: :server, kind: :microflow, public: false)
  end

  it 'matches legacy rule conditions with ordered argument and branch declarations' do
    legacy = builder
    legacy.decision({ rule: 'App.Check', pass: { 'App.Check.Value' => '$Input' } }) do
      on(true) { change_variable :Result, to: true }
      on(false) { change_variable :Result, to: false }
    end
    typed = builder
    typed.rule_decision('App.Check') do
      argument 'App.Check.Value', '$Input'
      on(true) { change_variable :Result, to: true }
      on(false) { change_variable :Result, to: false }
    end

    expect(typed.to_h.fetch(:body)).to eq(legacy.to_h.fetch(:body))
  end

  it 'keeps duplicate argument names, snapshots captured arguments and is atomic on failure' do
    flow = builder
    captured = nil
    input = +'001'
    flow.rule_decision('App.Check') do |decision|
      captured = decision
      decision.argument('Value', input)
      decision.argument('Value', false)
      decision.on(true) { end_flow }
    end
    captured.argument('Later', nil)
    captured.on(true) { error_event }
    input.replace('changed')
    expect(flow.to_h.dig(:body, 0, :condition, :pass)).to eq([%w[Value 001], ['Value', false]])
    decision = flow.to_h.fetch(:body).first
    expect(decision.fetch(:branches).fetch(true)).to eq(decision.fetch(:true_branch))
    expect(decision.fetch(:true_branch).first.fetch(:type)).to eq(:return_event)
    expect do
      flow.rule_decision('App.Check') do
        argument 'Value', nil
        raise 'stop'
      end
    end.to raise_error(RuntimeError, 'stop')
    expect(flow.to_h.fetch(:body).size).to eq(1)
  end

  it 'retains loop control restrictions inside rule branches' do
    flow = builder
    expect { flow.rule_decision('App.Check') { on(true) { break_loop } } }
      .to raise_error(ArgumentError, /only valid inside a loop/)
    flow.loop_over(:Items, as: :Item) do
      rule_decision('App.Check') { on(true) { break_loop } }
    end
    expect(flow.to_h.dig(:body, 0, :activities, 0, :true_branch, 0, :type)).to eq(:break_event)
  end

  it 'exports editable rule calls without literal hashes and preserves native flow documents' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-rule-decision-') do |directory| # rubocop:disable Metrics/BlockLength
      source = File.join(directory, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) do
          rule(:Rule) do
            parameter :Value, type: :string
            return_type :boolean
            return_value 'true'
          end
          microflow(:Check) do
            parameter :Input, type: :string
            decision({ rule: 'App.Rule', pass: { 'App.Rule.Value' => '$Input' } }) do
              on(true) { change_variable :Input, to: "'valid'" }
              on(false) { change_variable :Input, to: "'invalid'" }
            end
            return_type :string
            return_value :Input
          end
        end
      end
      root = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      file = Dir.glob(File.join(root, 'app', 'services', '**', '*.rb')).find { File.read(_1).include?('rule_decision') }
      text = File.read(file)
      expect(text).to include('rule_decision "App.Rule" do', 'argument "App.Rule.Value", "$Input"')
      expect(text).not_to include('pass:', 'decision ({')
      rebuilt = Mxrb::RubyApp.compile(root, File.join(directory, 'Rebuilt.mpr'))
      expect(documents(rebuilt)).to eq(documents(source))

      File.write(file, text.sub('argument "App.Rule.Value", "$Input"', 'argument "App.Rule.Value", "001"'))
      edited = Mxrb::RubyApp.compile(root, File.join(directory, 'Edited.mpr'))
      split = documents(edited).fetch('Check').dig('ObjectCollection', 'Objects').grep(Hash)
                               .find { _1['$Type'] == 'Microflows$ExclusiveSplit' }
      mappings = split.dig('SplitCondition', 'RuleCall', 'ParameterMappings').grep(Hash)
      expect(mappings.first.fetch('Argument')).to eq('001')
      expect(documents(edited).fetch('Rule')).to eq(documents(source).fetch('Rule'))
    end
  end

  def documents(path)
    Mxrb.open(path) do |project|
      mod = project.modules.find { _1.name == 'App' }
      (mod.microflows + mod.rules).to_h do |flow|
        [flow.name, project.mpr.parse_contents(project.mpr.unit(flow.id))]
      end
    end
  end
end
