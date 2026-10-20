# frozen_string_literal: true

# What a JSON import mapping makes on Mendix 11.12.1: the root object and its
# typed attributes (text, decimal, integer, boolean, date and time, null), a
# nested object found by its key and updated, an array of objects whose
# container is not mapped, an array whose container is, and an array of
# primitives wrapped into objects, each linked over an association owned by
# either side. Views.RunAll runs after startup and logs one "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"
payload = {
  name: 'order-1', total: 12.5, count: 3, paid: true, placed: '2024-05-01T10:15:30.000Z', note: nil,
  customer: { code: 'C1', label: 'Ada' }, tags: %w[a b],
  lines: [{ sku: 'x', qty: 1 }, { sku: 'y', qty: 2 }], box: { items: [{ sku: 'z' }] }
}
snippet = JSON.generate(payload)

value = lambda do |path, primitive, original = ''|
  { kind: :value, name: path.split('|').last.sub('(Value)', 'Value').capitalize, path:, primitive:,
    original: }
end
container = lambda do |kind, path, children, **options|
  { kind:, name: options.fetch(:name, path.split('|').last.capitalize), path:, children:,
    max_occurs: options.fetch(:max_occurs, 1), min_occurs: options.fetch(:min_occurs, 0) }
end
structure = [
  container.call(:object, '(Object)', [
                   value.call('(Object)|name', :string, '"order-1"'),
                   value.call('(Object)|total', :decimal, '12.5'),
                   value.call('(Object)|count', :integer, '3'),
                   value.call('(Object)|paid', :boolean, 'true'),
                   value.call('(Object)|placed', :date_time, '"2024-05-01T10:15:30.000Z"'),
                   value.call('(Object)|note', :string),
                   container.call(:object, '(Object)|customer', [
                                    value.call('(Object)|customer|code', :string, '"C1"'),
                                    value.call('(Object)|customer|label', :string, '"Ada"')
                                  ]),
                   container.call(:array, '(Object)|tags', [
                                    container.call(:wrapper, '(Object)|tags|(Wrapper)', [
                                                     value.call('(Object)|tags|(Wrapper)|(Value)', :string, '"a"')
                                                   ], name: 'Tag', max_occurs: -1)
                                  ]),
                   container.call(:array, '(Object)|lines', [
                                    container.call(:object, '(Object)|lines|(Object)', [
                                                     value.call('(Object)|lines|(Object)|sku', :string, '"x"'),
                                                     value.call('(Object)|lines|(Object)|qty', :integer, '1')
                                                   ], name: 'Line', max_occurs: -1)
                                  ]),
                   container.call(:object, '(Object)|box', [
                                    container.call(:array, '(Object)|box|items', [
                                                     container.call(:object, '(Object)|box|items|(Object)', [
                                                                      value.call('(Object)|box|items|(Object)|sku',
                                                                                 :string, '"z"')
                                                                    ], name: 'Item', max_occurs: -1)
                                                   ])
                                  ])
                 ], name: 'Root', min_occurs: 1)
]

attribute = lambda do |path, attribute, type, **options|
  { kind: :value, name: path.split('|').last.sub('(Value)', 'Value').capitalize, json_path: path, attribute:, type:,
    primitive: type, key: options.fetch(:key, false) }
end
object = lambda do |path, entity, association, children, **options|
  { kind: :object, element_type: options.fetch(:element_type, 'Object'),
    name: options.fetch(:name, entity.split('.').last),
    json_path: path, entity:, association:, children:, object_handling: options.fetch(:handling, :create),
    max_occurs: options.fetch(:max_occurs, 1), min_occurs: options.fetch(:min_occurs, 0) }
end
mapping = [
  object.call('(Object)', 'Views.Order', '', [
                attribute.call('(Object)|name', 'Views.Order.Name', :string),
                attribute.call('(Object)|total', 'Views.Order.Total', :decimal),
                attribute.call('(Object)|count', 'Views.Order.Count', :integer),
                attribute.call('(Object)|paid', 'Views.Order.Paid', :boolean),
                attribute.call('(Object)|placed', 'Views.Order.Placed', :date_time),
                attribute.call('(Object)|note', 'Views.Order.Note', :string),
                object.call('(Object)|customer', 'Views.Customer', 'Views.Order_Customer', [
                              attribute.call('(Object)|customer|code', 'Views.Customer.Code', :string, key: true),
                              attribute.call('(Object)|customer|label', 'Views.Customer.Label', :string)
                            ], handling: :find),
                object.call('(Object)|tags|(Wrapper)', 'Views.Tag', 'Views.Tag_Order', [
                              attribute.call('(Object)|tags|(Wrapper)|(Value)', 'Views.Tag.Value', :string)
                            ], element_type: 'Wrapper', max_occurs: -1),
                object.call('(Object)|lines|(Object)', 'Views.Line', 'Views.Line_Order', [
                              attribute.call('(Object)|lines|(Object)|sku', 'Views.Line.Sku', :string),
                              attribute.call('(Object)|lines|(Object)|qty', 'Views.Line.Qty', :integer)
                            ], max_occurs: -1),
                object.call('(Object)|box', 'Views.Box', 'Views.Box_Order', [
                              object.call('(Object)|box|items', 'Views.Items', 'Views.Items_Box', [
                                            object.call('(Object)|box|items|(Object)', 'Views.Item',
                                                        'Views.Item_Items', [
                                                          attribute.call('(Object)|box|items|(Object)|sku',
                                                                         'Views.Item.Sku', :string)
                                                        ], max_occurs: -1)
                                          ], element_type: 'Array')
                            ])
              ], name: 'Root', min_occurs: 1)
]

cases = {
  root: "$order/Name + '|' + toString($order/Total) + '|' + toString($order/Count) + '|' + toString($order/Paid)",
  placed: "formatDateTimeUTC($order/Placed, 'yyyy-MM-dd HH:mm:ss')",
  note: "if $order/Note = empty then 'empty' else $order/Note",
  customer: "$customer/Code + '|' + $customer/Label + '|' + toString($customers)",
  tags: 'toString($tags)', lines: 'toString($lines)', line_qty: 'toString($qty)', items: 'toString($items)',
  committed: 'toString($stored)'
}

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity :Order do
      string :Name
      decimal :Total
      integer :Count
      boolean :Paid
      datetime :Placed
      string :Note
      association 'Views.Customer', name: :Order_Customer, cardinality: :many_to_one
    end
    entity(:Customer) do
      string :Code
      string :Label
    end
    entity(:Tag) do
      string :Value
      association 'Views.Order', name: :Tag_Order, cardinality: :many_to_one
    end
    entity(:Line) do
      string :Sku
      integer :Qty
      association 'Views.Order', name: :Line_Order, cardinality: :many_to_one
    end
    entity(:Box) { association 'Views.Order', name: :Box_Order, cardinality: :many_to_one }
    entity(:Items) { association 'Views.Box', name: :Items_Box, cardinality: :many_to_one }
    entity(:Item) do
      string :Sku
      association 'Views.Items', name: :Item_Items, cardinality: :many_to_one
    end
    json_structure :OrderJson, snippet:, elements: structure
    import_mapping :ImportOrder, json_structure: 'Views.OrderJson', elements: mapping
    page :Home do
      title 'Import mapping oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Customer', as: :known, set: { Code: "'C1'", Label: "'old'" }, commit: true
      create_variable :json, type: :String, value: "'#{snippet.gsub("'", "''")}'"
      import_xml :json, mapping: 'Views.ImportOrder', as: :order, result_entity: 'Views.Order', content_type: :json
      retrieve_association :order, association: 'Views.Order_Customer', as: :customer
      retrieve_objects 'Views.Customer', as: :allCustomers
      aggregate :allCustomers, function: :count, as: :customers
      retrieve_objects 'Views.Tag', as: :tagList, xpath: '[Views.Tag_Order = $order]'
      aggregate :tagList, function: :count, as: :tags
      retrieve_objects 'Views.Line', as: :lineList, xpath: '[Views.Line_Order = $order]'
      aggregate :lineList, function: :count, as: :lines
      aggregate :lineList, function: :sum, attribute: 'Views.Line.Qty', as: :qty
      retrieve_objects 'Views.Item', as: :itemList,
                                     xpath: '[Views.Item_Items/Views.Items/Views.Items_Box/Views.Box/' \
                                            'Views.Box_Order = $order]'
      aggregate :itemList, function: :count, as: :items
      retrieve_objects 'Views.Order', as: :orders
      aggregate :orders, function: :count, as: :stored
      cases.each { |name, expression| log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: [expression] }
      call_microflow 'Views.ImportList', as: :mismatch
      log_message 'ORACLE array_for_object=[{1}]', node: oracle, parameters: ['$mismatch']
      return_value 'true'
    end
    microflow :ImportList do
      return_type :String
      create_variable :list, type: :String, value: "'[]'"
      import_xml :list, mapping: 'Views.ImportOrder', as: :none, result_entity: 'Views.Order', content_type: :json,
                        error: :custom_without_roll_back
      rescue_all do
        return_value "'error'"
      end
      return_value "if $none = empty then 'empty' else 'object'"
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
