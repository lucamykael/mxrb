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
end
# rubocop:enable Metrics/BlockLength
