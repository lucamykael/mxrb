# frozen_string_literal: true

# What a retrieve over an association gives on Mendix 11.12.1 after a reference
# changed in memory and was not committed: from the owner, through a
# non-persistent helper that refers to the owner, from the other side, and for a
# reference set. Views.RunAll runs after startup and logs one "ORACLE <case>=<value>"
# line each.

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
      log_message 'ORACLE owner_side=[{1}]', node: oracle, parameters: ["if $direct = empty then 'none' else $direct/Name"]
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
      retrieve_association :owner, association: 'Views.Holder_Tags', as: :tags
      aggregate :tags, function: :count, as: :tagCount
      log_message 'ORACLE reference_set=[{1}]', node: oracle, parameters: ['toString($tagCount)']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
