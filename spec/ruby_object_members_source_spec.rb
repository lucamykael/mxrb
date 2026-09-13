# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby object mutation member source' do
  after { Mxrb::RubyApp::Registry.reset! }

  def source_for(action)
    Mxrb::Exporter.allocate.send(:action_dsl_line, { 'Action' => action }, 0)
  end

  def decode_action(source)
    builder = Mxrb::Dsl::FlowBuilder.new('Example', runtime: nil, kind: :microflow, public: false)
    builder.instance_eval(source)
    builder.to_h.fetch(:body).first
  end

  it 'uses ordered member blocks for modern and legacy create/change actions' do
    values = ["'quoted value'", nil, false, '0', '$Other/Name', 'empty']
    members = values.map.with_index { |value, index| { 'Attribute' => "Name#{index}", 'Value' => value } }
    shapes = [
      ['Microflows$CreateObjectAction', 'Members', 'OutputVariableName', :create_object],
      ['Microflows$CreateChangeAction', 'Items', 'VariableName', :create_object],
      ['Microflows$ChangeObjectAction', 'Members', 'Variable', :change_object],
      ['Microflows$ChangeAction', 'Items', 'ChangeVariableName', :change_object]
    ]
    shapes.each do |type, collection, variable_key, semantic_type|
      source = source_for('$Type' => type, 'Entity' => 'App.Item', variable_key => 'item',
                          collection => [3, *members], 'Commit' => 'YesWithoutEvents', 'RefreshInClient' => true)
      expect(source).not_to include('set:', '{', '=>')
      expect(source).to include('set :Name0, to:', 'set :Name5, to:', 'commit: true, with_events: false, refresh: true')
      action = decode_action(source)
      expect(action).to include(type: semantic_type, commit: true, with_events: false, refresh: true)
      expect(action[:members].map { _1[:attribute] }).to eq((0..5).map { "Name#{_1}" })
      expect(action[:members].map { _1[:value] }).to eq(["'quoted value'", '', 'false', '0', '$Other/Name', 'empty'])
    end
  end

  it 'preserves mixed association operations and repeated attribute assignment order' do
    source = source_for(
      '$Type' => 'Microflows$ChangeObjectAction', 'Variable' => 'item', 'Members' => [3,
                                                                                      { 'Attribute' => 'Name',
                                                                                        'Value' => "'before'" },
                                                                                      {
                                                                                        'Association' => 'App.Item_Owner', 'Value' => '$Owner', 'Type' => 'Add'
                                                                                      },
                                                                                      { 'Attribute' => 'Name',
                                                                                        'Value' => { 'Value' => "'after'" } }]
    )
    expect(decode_action(source)[:members]).to eq([
                                                    { attribute: 'Name', value: "'before'" },
                                                    { association: 'App.Item_Owner', value: '$Owner',
                                                      operation: 'add' },
                                                    { attribute: 'Name', value: "'after'" }
                                                  ])
  end

  it 'does not add an empty block to mutations without members and retains legacy hash input' do
    source = source_for('$Type' => 'Microflows$CreateObjectAction', 'Entity' => 'App.Item',
                        'OutputVariableName' => 'item', 'Members' => [3])
    expect(source).not_to include(' do', 'set:')
    expect(decode_action(source)[:members]).to eq([])
    expect(decode_action('change_object :item, set: { Name: false }')[:members])
      .to eq([{ attribute: 'Name', value: false }])
  end

  def native_flow_bytes(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    mpr.all_units.filter_map do |unit|
      next unless mpr.parse_contents(unit)['$Type'] == 'Microflows$Microflow'

      [unit.fetch('UnitID'), mpr.content_bytes(unit)]
    end.to_h
  ensure
    mpr&.close
  end

  it 'roundtrips attribute-only and mixed object mutations with byte-identical native flow documents' do
    Dir.mktmpdir('mxrb-object-members-source-') do |directory|
      path = File.join(directory, 'Original.mpr')
      output = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Owner)
          entity(:Item) do
            string :Name
            integer :Amount
            boolean :Active
            association 'App.Owner', name: :Item_Owner
          end
          microflow(:Create) do
            create_object 'App.Item', as: :item, set: { Name: "'Draft'", Amount: 0, Active: false }
            change_object :item, set: { Name: nil, Amount: '$item/Amount + 1' }
          end
          microflow(:Mixed) do
            parameter :owner, type: 'App.Owner'
            create_object 'App.Item', as: :item do
              set :Name, to: "'Mixed'"
              set_association :Item_Owner, to: :owner
              set :Active, to: true
            end
            change_object :item do
              set :Name, to: "'Changed'"
              set_association :Item_Owner, to: :owner
            end
          end
        end
      end
      before = native_flow_bytes(path)
      Mxrb::Exporter.new(path, output, mode: :ruby).export!
      Dir.glob(File.join(output, 'app', 'services', '**', '*.rb')).each do |source|
        expect(File.read(source)).not_to include('set: {')
        expect(File.read(source)).to include('set :')
      end
      Mxrb::RubyApp.compile(output, rebuilt)
      expect(native_flow_bytes(rebuilt)).to eq(before)
      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Restored.mpr'))
      expect(native_flow_bytes(File.join(directory, 'Restored.mpr'))).to eq(before)
    end
  end
end
# rubocop:enable Metrics/BlockLength
