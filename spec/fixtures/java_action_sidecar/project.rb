# frozen_string_literal: true

# Java actions the opt-in sidecar compiles from the project's javasource and runs
# against the Ruby application: parameters of each type, attribute and
# association members, Core retrieves, commits, microflow calls (which run
# another Java action), log nodes, constants, a thrown exception and a source
# that uses an API the sidecar does not offer.

require 'mxrb'
require 'fileutils'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
text = { kind: :basic, type: { kind: :string } }
order = { kind: :basic, type: { kind: :concrete_entity, entity: 'Views.Order' } }
orders = { kind: :basic, type: { kind: :list, parameter: { kind: :concrete_entity, entity: 'Views.Order' } } }
oracle = "'ORACLE'"

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Customer) { string :Name }
    entity(:Tag) { string :Label }
    entity(:Order) do
      string :Name
      integer :Quantity
      association 'Views.Customer', name: :Order_Customer, cardinality: :many_to_one
      association 'Views.Tag', name: :Order_Tag, cardinality: :many_to_many
    end
    constant :Greeting, type: :string, value: 'hello from a constant'
    java_action :Echo, parameters: [
      { name: 'text', type: text },
      { name: 'count', type: { kind: :basic, type: { kind: :integer } } },
      { name: 'price', type: { kind: :basic, type: { kind: :decimal } } },
      { name: 'flag', type: { kind: :basic, type: { kind: :boolean } } },
      { name: 'when', type: { kind: :basic, type: { kind: :datetime } } }
    ], return_type: { kind: :string }
    java_action :Describe, parameters: [{ name: 'order', type: order }], return_type: { kind: :string }
    java_action :Fill, parameters: [{ name: 'order', type: order }], return_type: { kind: :boolean }
    java_action :Count, parameters: [{ name: 'name', type: text }], return_type: { kind: :integer }
    java_action :Largest, parameters: [], return_type: { kind: :concrete_entity, entity: 'Views.Order' }
    java_action :Total, parameters: [{ name: 'orders', type: orders }], return_type: { kind: :integer }
    java_action :CallFlow, parameters: [{ name: 'text', type: text }], return_type: { kind: :string }
    java_action :Shout, parameters: [{ name: 'text', type: text }], return_type: { kind: :string }
    java_action :Greeting, parameters: [], return_type: { kind: :string }
    java_action :Log, parameters: [], return_type: { kind: :boolean }
    java_action :Fail, parameters: [{ name: 'message', type: text }], return_type: { kind: :boolean }
    java_action :Unsupported, parameters: [], return_type: { kind: :string }
    java_action :Rename, parameters: [{ name: 'order', type: order }], return_type: { kind: :string }
    java_action :Accent, parameters: [], return_type: { kind: :string }
    microflow :Upper do
      parameter :Value, type: :String
      return_type :String
      call_java 'Views.Shout', as: :shouted, pass: { 'Views.Shout.text' => '$Value' }
      return_value '$shouted'
    end
    microflow :CatchFail do
      call_java 'Views.Fail', as: :failed, pass: { 'Views.Fail.message' => "'checked failure'" }
      rescue_all do
        log_message 'ORACLE fail_message={1}', node: oracle, parameters: ['$latestError/Message']
        log_message 'ORACLE fail_type={1}', node: oracle, parameters: ['$latestError/ErrorType']
      end
    end
    microflow :CatchUnsupported do
      call_java 'Views.Unsupported', as: :unsupported
      rescue_all do
        log_message 'ORACLE unsupported_type={1}', node: oracle, parameters: ['$latestError/ErrorType']
      end
    end
    page :Home do
      title 'Java action sidecar'
    end
    microflow :RunAll do
      return_type :Boolean
      call_java 'Views.Echo', as: :echo, pass: {
        'Views.Echo.text' => "'hi'", 'Views.Echo.count' => '7', 'Views.Echo.price' => '2.50',
        'Views.Echo.flag' => 'true', 'Views.Echo.when' => 'dateTimeUTC(2026, 1, 2, 3, 4, 5)'
      }
      log_message 'ORACLE echo={1}', node: oracle, parameters: ['$echo']
      create_object 'Views.Order', as: :order, set: { Name: "'first'", Quantity: '3' }, commit: true
      call_java 'Views.Describe', as: :before, pass: { 'Views.Describe.order' => '$order' }
      log_message 'ORACLE describe_before={1}', node: oracle, parameters: ['$before']
      call_java 'Views.Fill', as: :filled, pass: { 'Views.Fill.order' => '$order' }
      call_java 'Views.Describe', as: :after, pass: { 'Views.Describe.order' => '$order' }
      log_message 'ORACLE describe_after={1}', node: oracle, parameters: ['$after']
      log_message 'ORACLE customer={1}', node: oracle,
                                         parameters: ['$order/Views.Order_Customer/Views.Customer/Name']
      create_object 'Views.Order', as: :second, set: { Name: "'second'", Quantity: '5' }, commit: true
      call_java 'Views.Count', as: :count, pass: { 'Views.Count.name' => "'filled'" }
      log_message 'ORACLE count_filled={1}', node: oracle, parameters: ['toString($count)']
      call_java 'Views.Largest', as: :largest
      log_message 'ORACLE largest={1}', node: oracle, parameters: ['$largest/Name']
      create_list 'Views.Order', as: :orders
      change_list :orders, action: :add, value: '$order'
      change_list :orders, action: :add, value: '$second'
      call_java 'Views.Total', as: :total, pass: { 'Views.Total.orders' => '$orders' }
      log_message 'ORACLE total={1}', node: oracle, parameters: ['toString($total)']
      call_java 'Views.CallFlow', as: :flowed, pass: { 'Views.CallFlow.text' => "'nested'" }
      log_message 'ORACLE call_flow={1}', node: oracle, parameters: ['$flowed']
      call_java 'Views.Greeting', as: :greeting
      log_message 'ORACLE greeting={1}', node: oracle, parameters: ['$greeting']
      call_java 'Views.Log', as: :logged
      call_java 'Views.Rename', as: :renamed, pass: { 'Views.Rename.order' => '$second' }
      log_message 'ORACLE rename={1}', node: oracle, parameters: ['$renamed']
      retrieve_objects 'Views.Order', as: :renamedOrder, single: true, xpath: "[Name = 'renamed']"
      log_message 'ORACLE renamed_quantity={1}', node: oracle, parameters: ['toString($renamedOrder/Quantity)']
      call_java 'Views.Accent', as: :accent
      log_message 'ORACLE accent={1}', node: oracle, parameters: ['$accent']
      call_microflow 'Views.CatchFail'
      call_microflow 'Views.CatchUnsupported'
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength

imports = <<~JAVA
  import java.math.BigDecimal;
  import java.util.Date;
  import java.util.List;

  import com.mendix.core.Core;
  import com.mendix.systemwideinterfaces.core.IContext;
  import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
  import com.mendix.systemwideinterfaces.core.IMendixObject;
  import com.mendix.webui.CustomJavaAction;
JAVA

actions = {
  'Echo' => ['String', 'String text, Long count, BigDecimal price, Boolean flag, Date when', <<~BODY],
    return text + "|" + count + "|" + price.toPlainString() + "|" + flag + "|" + when.getTime();
  BODY
  'Describe' => ['String', 'IMendixObject order', <<~BODY],
    Object quantity = order.getValue(getContext(), "Quantity");
    List<IMendixIdentifier> tags = order.getValue(getContext(), "Views.Order_Tag");
    IMendixIdentifier customer = order.getValue(getContext(), "Views.Order_Customer");
    return order.getValue(getContext(), "Name") + " " + quantity + " " + quantity.getClass().getSimpleName()
        + " tags=" + tags.size() + " customer=" + (customer == null ? "none" : customer.getObjectType())
        + " changed=" + order.isChanged();
  BODY
  'Fill' => ['Boolean', 'IMendixObject order', <<~BODY],
    IContext context = getContext();
    IMendixObject customer = Core.instantiate(context, "Views.Customer");
    customer.setValue(context, "Name", "Ada");
    Core.commit(context, customer);
    IMendixObject tag = Core.instantiate(context, "Views.Tag");
    tag.setValue(context, "Label", "rush");
    Core.commit(context, tag);
    order.setValue(context, "Name", "filled");
    order.setValue(context, "Quantity", 4);
    order.setValue(context, "Views.Order_Customer", customer.getId());
    order.setValue(context, "Views.Order_Tag", List.of(tag.getId()));
    Core.commit(context, order);
    return true;
  BODY
  'Count' => ['Long', 'String name', <<~BODY],
    return (long) Core.createXPathQuery("//Views.Order[Name = $name]").setVariable("name", name)
        .execute(getContext()).size();
  BODY
  'Largest' => ['IMendixObject', nil, <<~BODY],
    return Core.createXPathQuery("//Views.Order").addSort("Quantity", false).setAmount(1)
        .execute(getContext()).get(0);
  BODY
  'Total' => ['Long', 'List<IMendixObject> orders', <<~BODY],
    long total = 0;
    for (IMendixObject order : orders) {
      Integer quantity = order.getValue(getContext(), "Quantity");
      total += quantity;
    }
    return total;
  BODY
  'CallFlow' => ['String', 'String text', <<~BODY],
    return Core.microflowCall("Views.Upper").withParam("Value", text).execute(getContext());
  BODY
  'Shout' => ['String', 'String text', 'return text.toUpperCase() + "!";'],
  'Greeting' => ['String', nil, 'return (String) Core.getConfiguration().getConstantValue("Views.Greeting");'],
  'Log' => ['Boolean', nil, <<~BODY],
    Core.getLogger("SidecarNode").info("hello from Java");
    return true;
  BODY
  'Fail' => ['Boolean', 'String message', 'throw new IllegalStateException(message);'],
  'Unsupported' => ['String', nil, 'return Core.getXASId();'],
  'Rename' => ['String', 'IMendixObject order', <<~BODY],
    views.proxies.Order proxy = views.proxies.Order.initialize(getContext(), order);
    String before = proxy.getName();
    proxy.setName("renamed");
    proxy.setQuantity(proxy.getQuantity() + 1);
    proxy.commit();
    return before + "->" + proxy.getName() + " " + views.proxies.Order.entityName;
  BODY
  'Accent' => ['String', nil, 'return views.Words.ACCENTED;']
}.freeze

java_source = lambda do |name, type, parameters, body|
  declared = parameters.to_s.split(', ')
  fields = declared.map { "\tprivate final #{_1};\n" }.join
  assignments = declared.map { "\n\t\tthis.#{_1.split.last} = #{_1.split.last};" }.join
  <<~JAVA
    package views.actions;

    #{imports}
    public class #{name} extends CustomJavaAction<#{type}>
    {
    #{fields}
    \tpublic #{name}(#{['IContext context', *declared].join(', ')})
    \t{
    \t\tsuper(context);#{assignments}
    \t}

    \t@java.lang.Override
    \tpublic #{type} executeAction() throws Exception
    \t{
    #{body.lines.map { "\t\t#{_1}" }.join}
    \t}
    }
  JAVA
end

directory = File.join(File.dirname(output_path), 'javasource', 'views', 'actions')
FileUtils.mkdir_p(directory)
actions.each do |name, (type, parameters, body)|
  File.write(File.join(directory, "#{name}.java"), java_source.call(name, type, parameters, "#{body.chomp}\n"))
end
# A helper saved as ISO-8859-1, as some projects keep their sources.
words = "package views;\n\npublic final class Words {\n\tpublic static final String ACCENTED = \"ação\";\n}\n"
File.binwrite(File.join(File.dirname(directory), 'Words.java'), words.encode(Encoding::ISO_8859_1))
