# frozen_string_literal: true

# How a change object adds to and removes from a reference set on Mendix
# 11.12.1: one object, the same object again, a list, removing one object and
# setting the set afterwards. Views.RunAll runs after startup and logs one
# "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"
count = lambda do |name|
  [[:retrieve_association, :holder, { association: 'Views.Holder_Tags', as: :"#{name}Tags" }],
   [:aggregate, :"#{name}Tags", { function: :count, as: :"#{name}Count" }],
   [:log_message, "ORACLE #{name}=[{1}]", { node: oracle, parameters: ["toString($#{name}Count)"] }]]
end

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Tag) { string :Name }
    entity :Holder do
      association 'Views.Tag', name: :Holder_Tags, cardinality: :many_to_many
    end
    page :Home do
      title 'Reference set changes oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Tag', as: :a, set: { Name: "'a'" }, commit: true
      create_object 'Views.Tag', as: :b, set: { Name: "'b'" }, commit: true
      create_object 'Views.Tag', as: :c, set: { Name: "'c'" }, commit: true
      create_object 'Views.Holder', as: :holder, commit: true
      steps = [
        [:added_one, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$a', operation: :add }],
        [:added_again, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$a', operation: :add }],
        [:added_second, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$b', operation: :add }],
        [:removed_one, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$a', operation: :remove }],
        [:removed_missing, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$c', operation: :remove }],
        [:set_one, ->(flow) { flow.set_association 'Views.Holder_Tags', to: '$c' }]
      ]
      steps.each do |name, change|
        change_object('holder') { change.call(self) }
        count.call(name).each { |method, first, options| public_send(method, first, **options) }
      end
      retrieve_objects 'Views.Tag', as: :all
      change_object 'holder' do
        set_association 'Views.Holder_Tags', to: '$all', operation: :add
      end
      count.call(:added_list).each { |method, first, options| public_send(method, first, **options) }
      retrieve_objects 'Views.Tag', as: :some, xpath: "[Name != 'c']"
      change_object 'holder' do
        set_association 'Views.Holder_Tags', to: '$some', operation: :remove
      end
      count.call(:removed_list).each { |method, first, options| public_send(method, first, **options) }
      commit :holder
      retrieve_objects 'Views.Holder', as: :stored, single: true
      retrieve_association :stored, association: 'Views.Holder_Tags', as: :storedTags
      aggregate :storedTags, function: :count, as: :storedCount
      log_message 'ORACLE committed=[{1}]', node: oracle, parameters: ['toString($storedCount)']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
