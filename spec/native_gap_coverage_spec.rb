# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Native regression edge contracts' do
  it 'validates explicit association storage and optional list-operation inputs' do
    entity = Mxrb::Dsl::EntityBuilder.new('Order')
    entity.association 'App.Customer', storage_format: :Column
    expect(entity.to_h.fetch(:associations).first.fetch(:storage_format)).to eq(:Column)
    expect { entity.association('App.Invalid', storage_format: :Other) }
      .to raise_error(ArgumentError, /storage format/)

    flow = Mxrb::Dsl::MicroflowBuilder.new('Lists', runtime: nil, kind: :microflow, public: false)
    flow.list_operation :head, :Items, as: :First
    flow.list_operation :find, :Items, as: :Found, with: :Other, expression: '$currentObject/Active'
    first, second = flow.to_h.fetch(:body)
    expect(first).to include(second: nil, expression: nil)
    expect(second).to include(second: 'Other', expression: '$currentObject/Active')
  end

  it 'writes association access, explicit storage, and both list-operation operands' do
    writer = Mxrb::Writer.allocate
    members = [{ kind: :association, name: 'Order_Customer', rights: :ReadWrite },
               { kind: :attribute, name: 'Number', rights: :ReadOnly }]
    docs = writer.send(:exact_access_member_docs, members, 'App', 'Order')
    expect(docs.first).to include('Association' => 'App.Order_Customer', 'Attribute' => '')
    expect(docs.last).to include('Association' => '', 'Attribute' => 'App.Order.Number')

    operation = writer.send(
      :activity_action_doc,
      type: :list_operation, operation: :find, variable: 'Items', output: 'Found',
      second: 'Other', expression: '$currentObject/Active'
    )
    expect(operation.fetch('NewOperation')).to include(
      'SecondListOrObjectName' => 'Other', 'Expression' => '$currentObject/Active'
    )
    minimal = writer.send(
      :activity_action_doc,
      type: :list_operation, operation: :head, variable: 'Items', output: 'First',
      second: nil, expression: nil
    )
    expect(minimal.fetch('NewOperation')).not_to have_key('SecondListOrObjectName')

    association = writer.send(
      :association_doc,
      { name: 'Order_Customer', type: :Reference, storage_format: :Table },
      from_id: 'from', to_id: 'to', previous: nil
    )
    expect(association.fetch('StorageFormat')).to eq('Table')
  end

  it 'exports explicit association storage and unique/duplicate parameter maps' do
    exporter = Mxrb::Exporter.allocate
    expect(exporter.send(:pass_source, [%w[A 1]])).to eq('{ "A" => 1 }')
    expect(exporter.send(:pass_source, [%w[A 1], %w[A 2]]))
      .to eq('[["A", 1], ["A", 2]]')

    association = Struct.new(
      :to_entity_id, :association_type, :owner, :name, :storage_format,
      :documentation, :parent_delete_behavior, :child_delete_behavior
    ).new('Target', :Reference, :Default, 'Source_Target', :Table, '', :NoAction, :NoAction)
    entity = Struct.new(:attributes, :persistable, :documentation, :name, :access_rules)
                   .new([], true, '', 'Source', [])
    target = Struct.new(:id, :name).new('Target', 'Target')
    mod = Struct.new(:entities, :name).new([target], 'App')
    source = exporter.send(:entity_source, entity, mod, [association])
    expect(source).to include('storage_format: :Table')
  end
end
# rubocop:enable Metrics/BlockLength
