# frozen_string_literal: true

# What a retrieve over an association gives on Mendix 11.12.1 after a reference
# changed in memory and was not committed: from the owner, through a
# non-persistent helper that refers to the owner, from the new and the former
# other side, from a new owner, for a reference set, from the other side of a
# one-to-one reference, and from an empty object. Views.RunAll runs after startup and logs one
# "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Target) { string :Name }
    entity :Holder do
      string :Name
      association 'Views.Target', name: :Holder_Target, cardinality: :many_to_one
      association 'Views.Target', name: :Holder_Tags, cardinality: :many_to_many
    end
    entity(:Twin) { association 'Views.Target', name: :Twin_Target, cardinality: :one_to_one }
    entity :Helper do
      non_persistent!
      association 'Views.Holder', name: :Helper_Holder, cardinality: :many_to_one
    end
    page :Home do
      title 'Uncommitted references oracle'
    end
    microflow :Describe do
      parameter :Helper, type: 'Views.Helper'
      return_type :String
      retrieve_association :Helper, association: 'Views.Helper_Holder', as: :owner
      retrieve_association :owner, association: 'Views.Holder_Target', as: :target
      return_value "if $target = empty then 'none' else $target/Name"
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Target', as: :old, set: { Name: "'old'" }, commit: true
      create_object 'Views.Target', as: :fresh, set: { Name: "'fresh'" }, commit: true
      create_object 'Views.Holder', as: :owner, commit: true do
        set :Name, to: "'owner'"
        set_association 'Views.Holder_Target', to: '$old'
      end
      change_object 'owner' do
        set_association 'Views.Holder_Target', to: '$fresh'
        set_association 'Views.Holder_Tags', to: '$fresh'
      end
      retrieve_association :owner, association: 'Views.Holder_Target', as: :direct
      log_message 'ORACLE owner_side=[{1}]', node: oracle,
                                             parameters: ["if $direct = empty then 'none' else $direct/Name"]
      create_object 'Views.Helper', as: :helper do
        set_association 'Views.Helper_Holder', to: '$owner'
      end
      call_microflow 'Views.Describe', as: :described do
        argument 'Views.Describe.Helper', '$helper'
      end
      log_message 'ORACLE through_helper=[{1}]', node: oracle, parameters: ['$described']
      retrieve_association :fresh, association: 'Views.Holder_Target', as: :owners
      aggregate :owners, function: :count, as: :ownerCount
      log_message 'ORACLE other_side=[{1}]', node: oracle, parameters: ['toString($ownerCount)']
      retrieve_association :old, association: 'Views.Holder_Target', as: :formerHolders
      aggregate :formerHolders, function: :count, as: :formerCount
      log_message 'ORACLE old_side=[{1}]', node: oracle, parameters: ['toString($formerCount)']
      create_object 'Views.Holder', as: :newHolder do
        set_association 'Views.Holder_Target', to: '$old'
      end
      retrieve_association :newHolder, association: 'Views.Holder_Target', as: :newTarget
      log_message 'ORACLE new_owner=[{1}]', node: oracle,
                                            parameters: ["if $newTarget = empty then 'none' else $newTarget/Name"]
      create_object 'Views.Twin', as: :twin, commit: true do
        set_association 'Views.Twin_Target', to: '$old'
      end
      retrieve_association :old, association: 'Views.Twin_Target', as: :twinOfOld
      retrieve_association :twinOfOld, association: 'Views.Twin_Target', as: :twinTarget
      log_message 'ORACLE one_to_one_reverse=[{1}]', node: oracle, parameters: ['$twinTarget/Name']
      retrieve_association :owner, association: 'Views.Holder_Tags', as: :tags
      aggregate :tags, function: :count, as: :tagCount
      log_message 'ORACLE reference_set=[{1}]', node: oracle, parameters: ['toString($tagCount)']
      retrieve_objects 'Views.Holder', as: :nobody, xpath: "[Name = 'nobody']", single: true
      retrieve_association :nobody, association: 'Views.Holder_Target', as: :emptyTarget
      log_message 'ORACLE empty_owner=[{1}]', node: oracle,
                                              parameters: ["if $emptyTarget = empty then 'empty' else 'object'"]
      retrieve_association :nobody, association: 'Views.Holder_Tags', as: :emptyTags
      aggregate :emptyTags, function: :count, as: :emptyTagCount
      log_message 'ORACLE empty_reference_set=[{1}]', node: oracle, parameters: ['toString($emptyTagCount)']
      retrieve_objects 'Views.Target', as: :noTarget, xpath: "[Name = 'nobody']", single: true
      retrieve_association :noTarget, association: 'Views.Holder_Target', as: :noHolders
      aggregate :noHolders, function: :count, as: :noHolderCount
      log_message 'ORACLE empty_other_side=[{1}]', node: oracle, parameters: ['toString($noHolderCount)']
      create_variable :visited, type: :Integer, value: '0'
      loop_over :noHolders, as: :noHolder do
        change_variable :visited, to: '$visited + 1'
      end
      log_message 'ORACLE empty_other_side_loop=[{1}]', node: oracle, parameters: ['toString($visited)']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
