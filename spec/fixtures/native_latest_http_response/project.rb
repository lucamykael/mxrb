# frozen_string_literal: true

# What $latestHttpResponse holds on Mendix 11.12.1 after a REST call: its status,
# reason, content and headers after a string result and after an import mapping,
# and in the error handler of a call answered with 400; and the body a custom
# request template sends, with an empty parameter. The calls reach the
# server of stub.rb. Views.RunAll runs after startup and logs one
# "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"
base = 'http://127.0.0.1:9395'
response = lambda do |prefix|
  {
    "#{prefix}_status" => 'toString($latestHttpResponse/StatusCode)',
    "#{prefix}_reason" =>
      "if $latestHttpResponse/ReasonPhrase = empty then 'empty' else $latestHttpResponse/ReasonPhrase",
    "#{prefix}_content" => "if $latestHttpResponse/Content = empty then 'empty' else $latestHttpResponse/Content"
  }
end
structure = [
  { kind: :object, name: 'Root', path: '(Object)', max_occurs: 1, min_occurs: 1,
    children: [{ kind: :value, name: 'Name', path: '(Object)|name', primitive: :string, original: '"remote"' }] }
]
mapping = [
  { kind: :object, element_type: 'Object', name: 'Root', json_path: '(Object)', entity: 'Views.Remote',
    association: '', object_handling: :create, max_occurs: 1, min_occurs: 1,
    children: [{ kind: :value, name: 'Name', json_path: '(Object)|name', attribute: 'Views.Remote.Name',
                 type: :string, primitive: :string, key: false }] }
]

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Remote) { string :Name }
    json_structure :RemoteJson, snippet: '{"name":"remote"}', elements: structure
    import_mapping :ImportRemote, json_structure: 'Views.RemoteJson', elements: mapping
    page :Home do
      title 'Latest HTTP response oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      call_rest method: :get, location: "#{base}/ok", result_handling: :string, as: :text
      log_message 'ORACLE text=[{1}]', node: oracle, parameters: ['$text']
      response.call('text').each do |name, expression|
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: [expression]
      end
      retrieve_association :latestHttpResponse, association: 'System.HttpHeaders', as: :headers
      list_operation :find, :headers, attribute: 'System.HttpHeader.Key', expression: "'X-Probe'", as: :probe
      log_message 'ORACLE header=[{1}]', node: oracle,
                                         parameters: ["if $probe = empty then 'none' else $probe/Value"]
      call_rest method: :get, location: "#{base}/ok", result_mapping: 'Views.ImportRemote', as: :remote,
                result_entity: 'Views.Remote'
      log_message 'ORACLE mapped=[{1}]', node: oracle, parameters: ['$remote/Name']
      response.call('mapped').each do |name, expression|
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: [expression]
      end
      create_variable :nothing, type: :String, value: 'empty'
      call_rest method: :post, location: "#{base}/echo", request_body: 'a={1}&b={2}&c={3}',
                request_parameters: ["'x y'", '$nothing', 'toString(1 + 2)'], result_handling: :string, as: :echo
      log_message 'ORACLE echo=[{1}]', node: oracle, parameters: ['$echo']
      call_microflow 'Views.CallBad', as: :bad
      log_message 'ORACLE bad=[{1}]', node: oracle, parameters: ['$bad']
      return_value 'true'
    end
    microflow :CallBad do
      return_type :String
      call_rest method: :get, location: "#{base}/bad", result_handling: :string, as: :never,
                error: :custom_without_roll_back
      rescue_all do
        return_value "toString($latestHttpResponse/StatusCode) + '|' + $latestHttpResponse/Content"
      end
      return_value "'no error'"
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
