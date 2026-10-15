# frozen_string_literal: true

# When Mendix 11.12.1 runs the microflow of a calculated attribute: after a
# create, a change, a commit, a retrieve of one object or of a list, a second
# read of the same variable, and for a microflow that is not passed the object.
# CalcFullName counts its calls in Views.Counter, which RunAll logs after each step.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Counter) { integer :Calls }
    entity :Person do
      string :First
      string :Last
      string :FullName, calculated: 'Views.CalcFullName'
      string :Fixed, calculated: 'Views.CalcFixed', pass_entity: false
    end
    microflow :CalcFullName do
      parameter :Person, type: 'Views.Person'
      return_type :String
      retrieve_objects 'Views.Counter', as: :Counter, single: true
      change_object 'Counter', set: { 'Views.Counter.Calls' => '$Counter/Calls + 1' }, commit: true
      return_value "$Person/First + ' ' + $Person/Last"
    end
    microflow :CalcFixed do
      return_type :String
      return_value "'fixed'"
    end
    microflow :Calls do
      return_type :String
      retrieve_objects 'Views.Counter', as: :Counter, single: true
      return_value 'toString($Counter/Calls)'
    end
    page :Home do
      title 'Calculated attributes oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Counter', as: :counter, set: { Calls: '0' }, commit: true
      create_object 'Views.Person', as: :person, set: { First: "'Ada'", Last: "'Lovelace'" }
      log_message 'ORACLE full_after_create={1}', node: oracle, parameters: ['$person/FullName']
      call_microflow 'Views.Calls', as: :afterCreate
      log_message 'ORACLE calls_after_create={1}', node: oracle, parameters: ['$afterCreate']
      log_message 'ORACLE full_read_again={1}', node: oracle, parameters: ['$person/FullName']
      call_microflow 'Views.Calls', as: :afterRead
      log_message 'ORACLE calls_after_read={1}', node: oracle, parameters: ['$afterRead']
      change_object 'person', set: { 'Views.Person.First' => "'Grace'" }
      log_message 'ORACLE full_after_change={1}', node: oracle, parameters: ['$person/FullName']
      call_microflow 'Views.Calls', as: :afterChange
      log_message 'ORACLE calls_after_change={1}', node: oracle, parameters: ['$afterChange']
      commit 'person'
      log_message 'ORACLE full_after_commit={1}', node: oracle, parameters: ['$person/FullName']
      call_microflow 'Views.Calls', as: :afterCommit
      log_message 'ORACLE calls_after_commit={1}', node: oracle, parameters: ['$afterCommit']
      retrieve_objects 'Views.Person', as: :stored, single: true
      log_message 'ORACLE full_after_retrieve={1}', node: oracle, parameters: ['$stored/FullName']
      call_microflow 'Views.Calls', as: :afterRetrieve
      log_message 'ORACLE calls_after_retrieve={1}', node: oracle, parameters: ['$afterRetrieve']
      create_object 'Views.Person', as: :other, set: { First: "'Alan'", Last: "'Turing'" }, commit: true
      call_microflow 'Views.Calls', as: :beforeList
      log_message 'ORACLE calls_before_list={1}', node: oracle, parameters: ['$beforeList']
      retrieve_objects 'Views.Person', as: :people
      call_microflow 'Views.Calls', as: :afterList
      log_message 'ORACLE calls_after_list={1}', node: oracle, parameters: ['$afterList']
      log_message 'ORACLE fixed={1}', node: oracle, parameters: ['$stored/Fixed']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
