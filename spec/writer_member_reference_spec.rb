# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# These contracts protect identifiers that Studio Pro resolves while loading a
# modern MPR, before ordinary model validation has a chance to report errors.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer, 'modern member references' do
  def document(project, name)
    raw = project.mpr.units_by_containment('Documents').find do |unit|
      project.parse_bson(unit)['Name'] == name
    end
    project.parse_bson(raw)
  end

  def flow_actions(project, name)
    objects = Mxrb::IO::BsonCodec.parse_array(
      document(project, name).dig('ObjectCollection', 'Objects')
    )[:items]
    objects.filter_map { _1['Action'] }
  end

  it 'qualifies a simple page input from its data-source return entity' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'page-members.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :App do
          entity(:Order) { string :Name }
          microflow(:LoadOrder) { return_type 'App.Order' }
          layout :Main
          page :Edit do
            layout 'App.Main'
            data_source microflow: :LoadOrder
            container(:Fields) { text_box :Name, attribute: :Name }
          end
        end
      end

      Mxrb.open(path) do |project|
        argument = document(project, 'Edit').dig('FormCall', 'Arguments', 1)
        input = argument.dig('Widgets', 1, 'Widgets', 1, 'Widgets', 1)
        expect(input.dig('AttributeRef', 'Attribute')).to eq('App.Order.Name')
      end
    end
  end

  it 'infers a unique module entity when a page has no typed data source' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'unique-page-member.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :App do
          entity(:Order) { string :Reference }
          layout :Main
          page(:Edit) { text_box :Reference, attribute: :Reference }
        end
      end

      Mxrb.open(path) do |project|
        input = document(project, 'Edit').dig('FormCall', 'Arguments', 1, 'Widgets', 1)
        expect(input.dig('AttributeRef', 'Attribute')).to eq('App.Order.Reference')
      end
    end
  end

  it 'qualifies create and change attributes and associations from object types' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'flow-members.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :App do
          entity :Customer
          entity :Order do
            string :Name
            decimal :Total
            association 'App.Customer', name: :Order_Customer
          end
          microflow :CreateOrder do
            parameter :customer, type: 'App.Customer'
            create_object 'App.Order', as: :order do
              set 'App.Order/Name', to: "'Draft'"
              set_association :Order_Customer, to: :customer
            end
            change_object :order do
              set :Total, to: 1
              set_association :Order_Customer, to: :customer
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        create, change = flow_actions(project, 'CreateOrder')
        create_items = Mxrb::IO::BsonCodec.parse_array(create['Items'])[:items]
        change_items = Mxrb::IO::BsonCodec.parse_array(change['Items'])[:items]
        expect(create_items.map { [_1['Attribute'], _1['Association']] }).to eq(
          [['App.Order.Name', ''], ['', 'App.Order_Customer']]
        )
        expect(change_items.map { [_1['Attribute'], _1['Association']] }).to eq(
          [['App.Order.Total', ''], ['', 'App.Order_Customer']]
        )
      end
    end
  end

  it 'qualifies a change attribute from an object parameter' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'parameter-member.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :App do
          entity(:Order) { string :Name }
          microflow :Rename do
            parameter :order, type: 'App.Order'
            change_object :order, set: { Name: "'Changed'" }
          end
        end
      end

      Mxrb.open(path) do |project|
        change = flow_actions(project, 'Rename').first
        item = Mxrb::IO::BsonCodec.parse_array(change['Items'])[:items].first
        expect(item['Attribute']).to eq('App.Order.Name')
      end
    end
  end

  it 'fails before writing an invalid unqualified change member' do
    Dir.mktmpdir do |dir|
      expect do
        Mxrb.define(File.join(dir, 'invalid-member.mpr')) do
          mendix_version '11.12.1'
          self.module(:App) do
            microflow(:UnknownObject) { change_object :unknown, set: { Name: "'x'" } }
          end
        end
      end.to raise_error(Mxrb::SerializationError, /cannot qualify attribute "Name"/)
    end
  end

  it 'handles qualified, ambiguous, absent, and legacy member-reference edges' do
    writer = described_class.new('edge.mpr', version: '11.12.1', modules: [])

    expect(writer.send(:qualified_attribute_identifier, 'Order.Name', 'App.Order'))
      .to eq('App.Order.Name')
    expect(writer.send(:qualified_attribute_identifier, 'Other.Name', 'App.Order')).to be_nil
    expect(writer.send(:qualified_attribute_identifier, :Name, '')).to be_nil
    expect(writer.send(:qualified_entity_name, nil, 'App')).to be_nil
    expect(writer.send(:qualified_entity_name, :Order)).to be_nil
    expect(writer.send(:qualified_entity_name, :Order, 'App')).to eq('App.Order')

    expect(writer.send(:object_entity_type, { '$Type' => 'DataTypes$StringType' }, 'App')).to be_nil
    expect(
      writer.send(
        :object_entity_type,
        { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Order' }, 'App'
      )
    ).to eq('App.Order')
    expect(writer.send(:qualified_artifact_parts, 'Load', 'App')).to eq(%w[App Load])
    expect(writer.send(:qualified_artifact_parts, 'Shared.Load', 'App')).to eq(%w[Shared Load])
    expect(writer.send(:flow_return_entity, 'Missing.Load', 'App')).to be_nil
    expect(writer.send(:module_entities, 'Missing')).to eq([])

    activity, variables = writer.send(
      :qualify_activity_members,
      [{ type: :create_object, entity: nil, variable: :unknown }], {}, 'App'
    )
    expect(activity.first[:entity]).to be_nil
    expect(variables).to eq({})
    association_activity, association_variables = writer.send(
      :qualify_activity_members,
      [{ type: :retrieve_association, association: :Missing, variable: :unknown }], {}, 'App'
    )
    expect(association_activity.first[:association]).to eq(:Missing)
    expect(association_variables).to eq({})
    loop_activity, loop_variables = writer.send(
      :qualify_activity_members,
      [{ type: :loop_over, variable: :missing, iterator: :item, activities: [] }], {}, 'App'
    )
    expect(loop_activity.first[:activities]).to eq([])
    expect(loop_variables).to eq({})
    decision = writer.send(
      :qualify_decision_activity,
      { type: :decision, true_branch: [], false_branch: [] }, {}, 'App'
    )
    expect(decision).to include(true_branch: [], false_branch: [])

    expect(writer.send(:qualified_association_identifier, :Missing, nil)).to be_nil
    expect do
      writer.send(:change_action_item_doc, { association: :Missing, value: nil })
    end.to raise_error(Mxrb::SerializationError, /cannot qualify association :Missing/)
  end
end
# rubocop:enable Metrics/BlockLength
