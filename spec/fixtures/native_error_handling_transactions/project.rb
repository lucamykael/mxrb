# frozen_string_literal: true

# Transactions around custom error handling on Mendix 11.12.1. Custom rolls the
# whole transaction back; CustomWithoutRollBack undoes a failed sub-microflow call;
# a failed Java action keeps its commits; after IContext.endTransaction commits are
# immediate and a call with custom handling runs in a transaction of its own.
# Count reads in the running transaction, Durable through another transaction.

require 'mxrb'
require 'fileutils'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
text = { kind: :basic, type: { kind: :string } }
oracle = "'ORACLE'"

# Steps shared by the scenarios below.
module ErrorHandlingSteps
  def commit_item(name) = create_object('Views.Item', as: :"item#{name}", set: { Name: "'#{name}'" }, commit: true)
  def fail_now = call_java('Views.Fail', as: :failed, pass: { 'Views.Fail.message' => "'failed'" })
  def end_transaction(name) = call_java('Views.EndTx', as: :"ended#{name}")

  def count(name)
    retrieve_objects 'Views.Item', as: :"list#{name}", xpath: "[Name='#{name}']"
    aggregate "list#{name}", function: :count, as: :"count#{name}"
    log_message "ORACLE seen_#{name}={1}", node: "'ORACLE'", parameters: ["toString($count#{name})"]
  end

  def durable(name, key = name)
    call_java 'Views.Durable', as: :"durable#{key}", pass: { 'Views.Durable.name' => "'#{name}'" }
    log_message "ORACLE durable_#{key}={1}", node: "'ORACLE'", parameters: ["toString($durable#{key})"]
  end
end
Mxrb::Dsl::FlowBodyDsl.include(ErrorHandlingSteps)

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Item) { string :Name }
    java_action :Fail, parameters: [{ name: 'message', type: text }], return_type: { kind: :boolean }
    java_action :CommitThenFail, parameters: [{ name: 'name', type: text }], return_type: { kind: :boolean }
    java_action :Durable, parameters: [{ name: 'name', type: text }], return_type: { kind: :integer }
    java_action :EndTx, parameters: [], return_type: { kind: :boolean }
    { 'B' => 'FailB', 'D' => 'FailD', 'F' => 'FailF' }.each do |name, flow|
      microflow flow do
        commit_item name
        fail_now
      end
    end
    microflow :WholeRollback do
      commit_item 'X'
      call_microflow 'Views.FailB'
      rescue_all do
        commit_item 'H'
      end
    end
    microflow :UndoCall do
      call_microflow 'Views.FailD'
      rescue_all { log_message 'ORACLE undo_caught=1', node: oracle }
    end
    microflow :JavaCommit do
      call_java 'Views.CommitThenFail', as: :committed, pass: { 'Views.CommitThenFail.name' => "'J'" }
      rescue_all { log_message 'ORACLE java_caught=1', node: oracle }
    end
    microflow :OwnEnd do
      commit_item 'S'
      end_transaction 'S'
      durable 'S'
    end
    microflow :GuardedOwnEnd do
      call_microflow 'Views.OwnEnd'
      rescue_all { log_message 'ORACLE never=1', node: oracle }
    end
    microflow :GuardedFailure do
      call_microflow 'Views.FailF'
      rescue_all { log_message 'ORACLE late_caught=1', node: oracle }
    end
    page :Home do
      title 'Error handling transactions'
    end
    microflow :RunAll do
      return_type :Boolean
      commit_item 'A'
      call_microflow 'Views.WholeRollback'
      %w[A X B H].each { count _1 }
      commit_item 'C'
      call_microflow 'Views.UndoCall'
      %w[C D].each { count _1 }
      call_microflow 'Views.JavaCommit'
      count 'J'
      durable 'H', 'H_before_end'
      end_transaction 'Root'
      %w[H C J].each { durable _1 }
      call_microflow 'Views.GuardedOwnEnd'
      call_microflow 'Views.GuardedFailure'
      count 'F'
      durable 'F'
      commit_item 'Z'
      durable 'Z'
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength

# The Studio Pro DSL writes custom handling without rollback; WholeRollback uses Custom.
mpr = Mxrb::IO::MprFile.open(output_path, readonly: false)
mpr.all_units.each do |unit|
  document = mpr.parse_contents(unit)
  next unless document['$Type'] == 'Microflows$Microflow' && document['Name'] == 'WholeRollback'

  calls = []
  visit = lambda do |node|
    case node
    when Hash
      calls << node if node['$Type'] == 'Microflows$MicroflowCallAction'
      node.each_value { visit.call(_1) }
    when Array then node.each { visit.call(_1) }
    end
  end
  visit.call(document)
  calls.each { _1['ErrorHandlingType'] = 'Custom' }
  mpr.update_unit(unit.fetch('UnitID'), document)
end
mpr.close

ACTIONS = {
  'Fail' => ['java.lang.Boolean', 'java.lang.String message', 'throw new views.ProbeException(message);'],
  'CommitThenFail' => ['java.lang.Boolean', 'java.lang.String name',
                       'IMendixObject item = Core.instantiate(getContext(), "Views.Item");
		item.setValue(getContext(), "Name", name);
		Core.commit(getContext(), item);
		throw new views.ProbeException("after commit");'],
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
