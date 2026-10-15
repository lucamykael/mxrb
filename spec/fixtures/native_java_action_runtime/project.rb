# frozen_string_literal: true

# Java actions written for this fixture observe what Mendix 11.12.1 reports for
# IMendixObject.isChanged, Core versions, the configured application root URL,
# $latestError of a thrown exception and IContext.endTransaction. Durable counts
# the items another transaction sees.

require 'mxrb'
require 'fileutils'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
text = { kind: :basic, type: { kind: :string } }
item = { kind: :basic, type: { kind: :concrete_entity, entity: 'Views.Item' } }
oracle = "'ORACLE'"

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Item) { string :Name }
    java_action :Fail, parameters: [{ name: 'message', type: text }], return_type: { kind: :boolean }
    java_action :FailRuntime, parameters: [{ name: 'message', type: text }], return_type: { kind: :boolean }
    java_action :ModelVersion, parameters: [], return_type: { kind: :string }
    java_action :RuntimeVersion, parameters: [], return_type: { kind: :string }
    java_action :IsChanged, parameters: [{ name: 'item', type: item }], return_type: { kind: :boolean }
    java_action :Durable, parameters: [{ name: 'name', type: text }], return_type: { kind: :integer }
    java_action :EndTx, parameters: [], return_type: { kind: :boolean }
    microflow :CatchFail do
      call_java 'Views.Fail', as: :failed, pass: { 'Views.Fail.message' => "'checked failure'" }
      rescue_all do
        log_message 'ORACLE checked_message={1}', node: oracle, parameters: ['$latestError/Message']
        log_message 'ORACLE checked_type={1}', node: oracle, parameters: ['$latestError/ErrorType']
      end
    end
    microflow :CatchRuntime do
      call_java 'Views.FailRuntime', as: :failed, pass: { 'Views.FailRuntime.message' => "'runtime failure'" }
      rescue_all do
        log_message 'ORACLE runtime_message={1}', node: oracle, parameters: ['$latestError/Message']
        log_message 'ORACLE runtime_type={1}', node: oracle, parameters: ['$latestError/ErrorType']
      end
    end
    microflow :NestedEnd do
      create_object 'Views.Item', as: :nested, set: { Name: "'nested'" }, commit: true
      call_java 'Views.EndTx', as: :ended
      call_java 'Views.Durable', as: :durable, pass: { 'Views.Durable.name' => "'nested'" }
      log_message 'ORACLE nested_durable={1}', node: oracle, parameters: ['toString($durable)']
    end
    microflow :Changes do
      create_object 'Views.Item', as: :item, set: { Name: "'a'" }
      call_java 'Views.IsChanged', as: :newSet, pass: { 'Views.IsChanged.item' => '$item' }
      log_message 'ORACLE new_set={1}', node: oracle, parameters: ['toString($newSet)']
      create_object 'Views.Item', as: :blank
      call_java 'Views.IsChanged', as: :newBlank, pass: { 'Views.IsChanged.item' => '$blank' }
      log_message 'ORACLE new_blank={1}', node: oracle, parameters: ['toString($newBlank)']
      commit 'item'
      call_java 'Views.IsChanged', as: :committed, pass: { 'Views.IsChanged.item' => '$item' }
      log_message 'ORACLE committed={1}', node: oracle, parameters: ['toString($committed)']
      change_object 'item', set: { 'Views.Item.Name' => "'b'" }
      call_java 'Views.IsChanged', as: :changed, pass: { 'Views.IsChanged.item' => '$item' }
      log_message 'ORACLE changed={1}', node: oracle, parameters: ['toString($changed)']
      change_object 'item', set: { 'Views.Item.Name' => "'a'" }
      call_java 'Views.IsChanged', as: :reverted, pass: { 'Views.IsChanged.item' => '$item' }
      log_message 'ORACLE reverted={1}', node: oracle, parameters: ['toString($reverted)']
      commit 'item'
      change_object 'item', set: { 'Views.Item.Name' => "'a'" }
      call_java 'Views.IsChanged', as: :same, pass: { 'Views.IsChanged.item' => '$item' }
      log_message 'ORACLE same_value={1}', node: oracle, parameters: ['toString($same)']
    end
    page :Home do
      title 'Java action runtime oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Changes'
      call_java 'Views.ModelVersion', as: :model
      log_message 'ORACLE model_version={1}', node: oracle, parameters: ['$model']
      call_java 'Views.RuntimeVersion', as: :runtime
      log_message 'ORACLE runtime_version={1}', node: oracle, parameters: ['$runtime']
      call_microflow 'Views.CatchFail'
      call_microflow 'Views.CatchRuntime'
      call_microflow 'Views.NestedEnd'
      create_object 'Views.Item', as: :root, set: { Name: "'root'" }, commit: true
      call_java 'Views.Durable', as: :before, pass: { 'Views.Durable.name' => "'root'" }
      log_message 'ORACLE root_before_end={1}', node: oracle, parameters: ['toString($before)']
      call_java 'Views.EndTx', as: :ended
      call_java 'Views.Durable', as: :after, pass: { 'Views.Durable.name' => "'root'" }
      log_message 'ORACLE root_after_end={1}', node: oracle, parameters: ['toString($after)']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength

ACTIONS = {
  'Fail' => ['java.lang.Boolean', 'java.lang.String message', 'throw new views.ProbeException(message);'],
  'FailRuntime' => ['java.lang.Boolean', 'java.lang.String message', 'throw new RuntimeException(message);'],
  'ModelVersion' => ['java.lang.String', nil, 'return Core.getModelVersion();'],
  'RuntimeVersion' => ['java.lang.String', nil, 'return Core.getRuntimeVersion();'],
  'IsChanged' => ['java.lang.Boolean', 'IMendixObject item', 'return item.getMendixObject().isChanged();'],
  'EndTx' => ['java.lang.Boolean', nil, 'getContext().endTransaction();
		return true;'],
  'Durable' => ['java.lang.Long', 'java.lang.String name', 'final long[] count = { -1 };
		Thread reader = new Thread(() -> {
			try {
				count[0] = Core.createXPathQuery("//Views.Item[Name=$name]").setVariable("name", name)
					.execute(Core.createSystemContext()).size();
			} catch (Exception e) {
				count[0] = -2;
			}
		});
		reader.start();
		reader.join();
		return count[0];']
}.freeze

def java_action(name, type, parameter, body) # rubocop:disable Metrics/MethodLength
  field, assignment = if parameter
                        ["\n\tprivate final #{parameter};\n",
                         "\n\t\tthis.#{parameter.split.last} = #{parameter.split.last};"]
                      else
                        ['', '']
                      end
  <<~JAVA
    package views.actions;

    import com.mendix.core.Core;
    import com.mendix.systemwideinterfaces.core.IContext;
    import com.mendix.systemwideinterfaces.core.IMendixObject;
    import com.mendix.webui.CustomJavaAction;
    // BEGIN EXTRA CODE
    // END EXTRA CODE

    public class #{name} extends CustomJavaAction<#{type}>
    {#{field}
    \tpublic #{name}(#{['IContext context', parameter].compact.join(', ')})
    \t{
    \t\tsuper(context);#{assignment}
    \t}

    \t@java.lang.Override
    \tpublic #{type} executeAction() throws Exception
    \t{
    \t\t// BEGIN USER CODE
    \t\t#{body}
    \t\t// END USER CODE
    \t}

    \t@java.lang.Override
    \tpublic java.lang.String toString()
    \t{
    \t\treturn "#{name}";
    \t}
    }
  JAVA
end

directory = File.join(File.dirname(output_path), 'javasource', 'views')
FileUtils.mkdir_p(File.join(directory, 'actions'))
ACTIONS.each do |name, (type, parameter, body)|
  File.write(File.join(directory, 'actions', "#{name}.java"), java_action(name, type, parameter, body))
end
File.write(File.join(directory, 'ProbeException.java'), <<~JAVA)
  package views;

  public class ProbeException extends Exception
  {
  \tpublic ProbeException(String message)
  \t{
  \t\tsuper(message);
  \t}
  }
JAVA
