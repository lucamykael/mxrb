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
    enumeration :Status do
      value :Open, captions: { 'en_US' => 'Open', 'pt_BR' => 'Aberto' }
      value :Closed, captions: { 'en_US' => 'Closed', 'pt_BR' => 'Fechado' }
    end
    entity(:Customer) { string :Name }
    entity(:Document) { generalizes 'System.FileDocument' }
    entity(:Draft) do
      non_persistent!
      string :Note
    end
    entity(:Tag) { string :Label }
    entity(:Order) do
      string :Name
      integer :Quantity
      enum :Status, enumeration: 'Views.Status'
      association 'Views.Customer', name: :Order_Customer, cardinality: :many_to_one
      association 'Views.Tag', name: :Order_Tag, cardinality: :many_to_many
    end
    constant :Greeting, type: :string, value: 'hello from a constant'
    dataset :CustomerNames do
      parameter :Prefix, string
      oql 'SELECT c.Name AS Name FROM Views.Customer AS c WHERE c.Name LIKE $Prefix'
    end
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
    java_action :Inspect, parameters: [{ name: 'order', type: order }], return_type: { kind: :string }
    java_action :Track, parameters: [{ name: 'order', type: order }], return_type: { kind: :string }
    java_action :Captions, parameters: [], return_type: { kind: :string }
    java_action :Microflows, parameters: [], return_type: { kind: :string }
    java_action :Store, parameters: [], return_type: { kind: :string }
    java_action :Oql, parameters: [], return_type: { kind: :string }
    java_action :Register, parameters: [], return_type: { kind: :boolean }
    java_action :Json, parameters: [], return_type: { kind: :string }
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
      call_java 'Views.Inspect', as: :inspected, pass: { 'Views.Inspect.order' => '$order' }
      log_message 'ORACLE inspect={1}', node: oracle, parameters: ['$inspected']
      call_java 'Views.Track', as: :tracked, pass: { 'Views.Track.order' => '$order' }
      log_message 'ORACLE track={1}', node: oracle, parameters: ['$tracked']
      call_java 'Views.Captions', as: :captions
      log_message 'ORACLE captions={1}', node: oracle, parameters: ['$captions']
      call_java 'Views.Microflows', as: :microflows
      log_message 'ORACLE microflows={1}', node: oracle, parameters: ['$microflows']
      call_java 'Views.Store', as: :stored
      log_message 'ORACLE store={1}', node: oracle, parameters: ['$stored']
      call_java 'Views.Oql', as: :oql
      log_message 'ORACLE oql={1}', node: oracle, parameters: ['$oql']
      call_java 'Views.Register', as: :registered
      call_java 'Views.Json', as: :json
      log_message 'ORACLE json={1}', node: oracle, parameters: ['$json']
      call_microflow 'Views.CatchFail'
      call_microflow 'Views.CatchUnsupported'
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
  security do
    security_level 'Off'
    user_role 'Administrator', admin: true
    user_role 'Guest'
    admin_user_role 'Administrator'
    guest_access true, role: 'Guest'
  end
end
# rubocop:enable Metrics/BlockLength

imports = <<~JAVA
  import java.math.BigDecimal;
  import java.util.Date;
  import java.util.List;
  import java.util.Map;

  import com.mendix.core.Core;
  import com.mendix.core.conf.RuntimeVersion;
  import com.mendix.utils.ListUtils;
  import com.mendix.systemwideinterfaces.connectionbus.data.IDataRow;
  import com.mendix.systemwideinterfaces.connectionbus.data.IDataTable;
  import com.mendix.systemwideinterfaces.connectionbus.requests.IParameterMap;
  import com.mendix.systemwideinterfaces.connectionbus.requests.types.IOQLTextGetRequest;
  import com.mendix.systemwideinterfaces.core.IDataType;
  import com.mendix.systemwideinterfaces.core.IMendixObjectMember;
  import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;
  import com.mendix.systemwideinterfaces.core.meta.IMetaEnumValue;
  import com.mendix.systemwideinterfaces.core.meta.IMetaObject;
  import com.mendix.systemwideinterfaces.core.meta.IMetaPrimitive;
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
  'Unsupported' => ['String', nil, 'return Core.notInTheRuntimeApi();'],
  'Rename' => ['String', 'IMendixObject order', <<~BODY],
    views.proxies.Order proxy = views.proxies.Order.initialize(getContext(), order);
    String before = proxy.getName();
    proxy.setName("renamed");
    proxy.setQuantity(proxy.getQuantity() + 1);
    proxy.commit();
    return before + "->" + proxy.getName() + " " + views.proxies.Order.entityName;
  BODY
  'Accent' => ['String', nil, 'return views.Words.ACCENTED;'],
  'Inspect' => ['String', 'IMendixObject order', <<~BODY],
    IContext context = getContext();
    IMetaObject meta = Core.getMetaObject("Views.Order");
    StringBuilder out = new StringBuilder(meta.getName() + " " + meta.getModuleName() + " " + meta.isPersistable());
    for (IMetaPrimitive primitive : meta.getMetaPrimitives()) {
      out.append(" ").append(primitive.getName()).append(":").append(primitive.getType());
    }
    for (IMetaAssociation association : meta.getMetaAssociationsParent()) {
      out.append(" ").append(association.getName()).append(">").append(association.getChild().getName())
          .append(":").append(association.getType());
    }
    out.append(" |");
    for (Map.Entry<String, ? extends IMendixObjectMember<?>> member : order.getMembers(context).entrySet()) {
      out.append(" ").append(member.getKey()).append("=").append(member.getValue().getClass().getSimpleName());
    }
    IMetaObject document = Core.getMetaObject("Views.Document");
    return out + " | " + order.getState() + " " + order.isNew() + " " + order.getMetaObject().getName()
        + " " + document.getSuperName() + " " + document.isFileDocument() + " " + Core.isSubClassOf("System.FileDocument", "Views.Document")
        + " " + Core.getMetaObject("System.FileDocument").getSubObjects().stream().anyMatch(sub -> sub.getName().equals("Views.Document"));
  BODY
  'Track' => ['String', 'IMendixObject order', <<~BODY],
    IContext context = getContext();
    order.setValue(context, "Name", "tracked");
    IMendixObjectMember<?> name = order.getMember(context, "Name");
    IMendixObject fresh = Core.instantiate(context, "Views.Order");
    return name.getOriginalValue(context) + "->" + name.getValue(context) + " " + name.getState() + " "
        + order.getMember(context, "Quantity").getState() + " " + order.getState() + " " + fresh.getState()
        + " " + fresh.isNew() + " changed=" + order.getChangedMembers(context).size();
  BODY
  'Captions' => ['String', nil, <<~BODY],
    IMetaEnumValue closed = Core.getMetaObject("Views.Order").getMetaPrimitive("Status").getEnumeration()
        .getEnumValues().get("Closed");
    return views.proxies.Status.Open.getCaption("pt_BR") + "|" + views.proxies.Status.Open.getCaption() + "|"
        + views.proxies.Status.Closed.getCaption("de_DE") + "|"
        + Core.getInternationalizedString("pt_BR", closed.getI18NCaptionKey()) + "|"
        + Core.getInternationalizedString("en_US", "unknown-key") + "|"
        + RuntimeVersion.getInstance().getMajorVersion() + "|" + ListUtils.map(List.of(1, 2), i -> i * 2);
  BODY
  'Microflows' => ['String', nil, <<~BODY],
    Map<String, IDataType> parameters = Core.getInputParameters("Views.Upper");
    IDataType value = parameters.get("Value");
    return Core.getMicroflowNames().contains("Views.Upper") + " " + parameters.keySet() + " " + value.getType()
        + " " + Core.getReturnType("Views.Upper").getDSLType() + " " + Core.createDataType("Views.Order", "Quantity").getType()
        + " " + Core.createDataType("[Views.Order]").isList() + " " + Core.getInputParameters("Views.Missing");
  BODY
  'Store' => ['String', nil, <<~BODY],
    IContext context = getContext();
    IMendixObject document = Core.instantiate(context, "Views.Document");
    Core.storeFileDocumentContent(context, document, "note.txt",
        new java.io.ByteArrayInputStream("hello".getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    Core.commit(context, document);
    String content = new String(Core.getFileDocumentContent(context, document).readAllBytes(),
        java.nio.charset.StandardCharsets.UTF_8);
    com.mendix.webui.FeedbackHelper.addTextMessageFeedback(context,
        com.mendix.systemwideinterfaces.core.IFeedback.MessageType.WARNING, "stored " + content, true);
    com.mendix.webui.FeedbackHelper.addRefreshClass(context, "Views.Document");
    return content + " " + document.getValue(context, "Name") + " " + document.getValue(context, "Size")
        + " " + Core.retrieveXPathQueryAggregate(context, "COUNT(//Views.Order)")
        + " " + Core.retrieveXPathQueryAggregate(context, "SUM(//Views.Order/Quantity)")
        + " " + Core.retrieveXPathQueryAggregate(context, "max(//Views.Order[Quantity < 6]/Quantity)");
  BODY
  'Json' => ['String', nil, <<~BODY],
    com.mendix.thirdparty.org.json.JSONObject input = new com.mendix.thirdparty.org.json.JSONObject(
        "{\\"name\\": \\"Ada\\", \\"tags\\": [1, 2.5, \\"x\\", null], \\"nested\\": {\\"ok\\": true}}");
    com.mendix.thirdparty.org.json.JSONArray tags = input.getJSONArray("tags");
    com.mendix.thirdparty.org.json.JSONObject out = new com.mendix.thirdparty.org.json.JSONObject();
    out.put("name", input.getString("name"));
    out.put("count", tags.length());
    out.put("sum", tags.getInt(0) + tags.getDouble(1));
    out.put("missing", com.mendix.thirdparty.org.json.JSONObject.NULL);
    out.put("ok", input.getJSONObject("nested").getBoolean("ok"));
    out.put("list", List.of("a", 1));
    return out + "|" + input.optString("none", "fallback") + "|" + tags.isNull(3) + "|"
        + getContext().getRuntimeRequest().isPresent() + "|" + (context() == getContext());
  BODY
  'Register' => ['Boolean', nil, <<~BODY],
    Core.addRequestHandler("/hello/", new views.Hello());
    return true;
  BODY
  'Oql' => ['String', nil, <<~BODY]
    IContext context = getContext();
    IOQLTextGetRequest request = Core.createOQLTextGetRequest();
    request.setQuery("SELECT c.Name AS Name, c.ID AS Id FROM Views.Customer c WHERE c.Name = $name");
    IParameterMap parameters = request.createParameterMap();
    parameters.put("$name", "Ada");
    request.setParameters(parameters);
    IDataTable table = Core.retrieveOQLDataTable(context, request);
    IDataRow row = table.getRows().get(0);
    IMendixIdentifier id = row.getValue(context, "Id");
    IDataTable counts = Core.retrieveOQLDataTable(context,
        "SELECT t.Label AS Label, COUNT(t.ID) AS Uses FROM Views.Tag t GROUP BY t.Label", 1, 0);
    IDataRow count = counts.iterator().next();
    return table.getRowCount() + " " + table.getSchema().getColumnSchema(1).getName() + " " + row.getValue(context, 0)
        + " " + id.getObjectType() + " " + Core.retrieveId(context, id).getValue(context, "Name") + " "
        + count.getValue(context, "label") + "=" + count.getValue(context, counts.getSchema().getColumnSchema("Uses"))
        + " " + count.getValue(context, 1).getClass().getSimpleName();
  BODY
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
File.write(File.join(File.dirname(directory), 'Hello.java'), <<~JAVA)
  package views;

  import com.mendix.core.Core;
  import com.mendix.externalinterface.connector.RequestHandler;
  import com.mendix.m2ee.api.IMxRuntimeRequest;
  import com.mendix.m2ee.api.IMxRuntimeResponse;
  import com.mendix.systemwideinterfaces.core.IContext;
  import com.mendix.systemwideinterfaces.core.IMendixObject;
  import com.mendix.systemwideinterfaces.core.ISession;

  public class Hello extends RequestHandler
  {
  	@Override
  	protected void processRequest(IMxRuntimeRequest request, IMxRuntimeResponse response, String path) throws Exception
  	{
  		ISession session = getSessionFromRequest(request);
  		boolean fresh = session == null;
  		if (fresh) {
  			session = Core.initializeGuestSession();
  			response.addCookie(getSessionCookieName(), session.getId().toString(), "/", "", -1, true);
  		}
  		IContext context = session.createContext();
  		IMendixObject customer = Core.createXPathQuery("//Views.Customer").execute(context).get(0);
  		long number = customer.getId().toLong();
  		IMendixObject same = Core.createMendixIdentifier(number).getObject();
  		response.setStatus(IMxRuntimeResponse.OK);
  		response.setContentType("text/plain");
  		response.addHeader("X-Path-Info", request.getHttpServletRequest().getPathInfo());
  		response.getWriter().write(path + " q=" + request.getParameter("q") + " fresh=" + fresh
  			+ " anonymous=" + session.getUser(context).isAnonymous() + " " + session.getUserName().equals("Anonymous_" + session.getId())
  			+ " " + same.getValue(context, "Name") + " " + (number == customer.getId().toLong())
  			+ " guests=" + Core.getConfiguration().getEnableGuestLogin() + " " + request.getHttpServletRequest().getServletPath());
  	}
  }
JAVA
# A helper saved as ISO-8859-1, as some projects keep their sources.
words = "package views;\n\npublic final class Words {\n\tpublic static final String ACCENTED = \"ação\";\n}\n"
File.binwrite(File.join(File.dirname(directory), 'Words.java'), words.encode(Encoding::ISO_8859_1))
