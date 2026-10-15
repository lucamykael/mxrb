# frozen_string_literal: true

# What MxModelReflection reads from a Mendix 11.12.1 Runtime: the meta objects with
# their primitives, enumerations and generalizations, the associations, the
# microflows with their parameter and return types, and the languages. DumpMetamodel
# writes them as JSON to the Runtime's temporary directory. MXRB_ORACLE_MENDIX_VERSION
# records another Runtime, whose System module script/extract_system_metamodel keeps.

require 'mxrb'
require 'fileutils'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version ENV.fetch('MXRB_ORACLE_MENDIX_VERSION', '11.12.1')
  self.module :Other do
    entity(:Thing) { string :Label }
  end
  self.module :Views do
    enumeration :Kind do
      value :Alpha, caption: 'First kind'
      value :Beta, caption: 'Second kind'
    end
    entity :Base do
      string :Name, length: 100
      autonumber :Code
    end
    entity :Item do
      generalizes 'Views.Base'
      decimal :Price
      integer :Count
      long :Big
      datetime :When
      boolean :Flag
      string :Free, length: 0
      enum :Kind, enumeration: 'Views.Kind'
      association 'Views.Base', name: :Item_Base, cardinality: :many_to_one
      association 'Other.Thing', name: :Item_Thing, cardinality: :many_to_one
    end
    entity :Special do
      generalizes 'Views.Item'
      boolean :Extra
    end
    entity :Tag do
      string :Label
      association 'Views.Item', name: :Tag_Item, cardinality: :many_to_many
    end
    entity :Account do
      generalizes 'System.User'
      string :Nick
    end
    entity :Document do
      generalizes 'System.FileDocument'
    end
    entity :Audited do
      system_members owner: true, created_date: true, changed_date: true, changed_by: true
      string :Note
    end
    entity :Draft do
      non_persistent!
      string :Note
    end
    java_action :DumpMetamodel, parameters: [], return_type: { kind: :string }
    microflow :Act do
      parameter :Text, type: :String
      parameter :Number, type: :Integer
      parameter :Amount, type: :Decimal
      parameter :When, type: :DateTime
      parameter :Flag, type: :Boolean
      parameter :Choice, type: enum_of('Views.Kind')
      parameter :Item, type: object_of('Views.Item')
      parameter :Items, type: list_of('Views.Item')
      return_type list_of('Views.Tag')
      return_value 'empty'
    end
    microflow :Choose do
      return_type enum_of('Views.Kind')
      return_value 'Views.Kind.Alpha'
    end
    page :Home do
      title 'Metamodel'
    end
    microflow :RunAll do
      return_type :Boolean
      call_java 'Views.DumpMetamodel', as: :path
      log_message 'ORACLE dumped={1}', node: "'ORACLE'", parameters: ['$path']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength

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
    import com.mendix.systemwideinterfaces.core.IDataType;
    import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;
    import com.mendix.systemwideinterfaces.core.meta.IMetaEnumValue;
    import com.mendix.systemwideinterfaces.core.meta.IMetaObject;
    import com.mendix.systemwideinterfaces.core.meta.IMetaPrimitive;
    import com.mendix.webui.CustomJavaAction;

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

    \t// BEGIN EXTRA CODE
    #{EXTRA}
    \t// END EXTRA CODE

    \t@java.lang.Override
    \tpublic java.lang.String toString()
    \t{
    \t\treturn "#{name}";
    \t}
    }
  JAVA
end

EXTRA = <<~'JAVA'.gsub(/^/, '    ').strip
  private static String text(String value) {
  	if (value == null) return "null";
  	StringBuilder out = new StringBuilder("\"");
  	for (char c : value.toCharArray()) {
  		if (c == '"' || c == '\\') out.append('\\').append(c);
  		else if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
  		else out.append(c);
  	}
  	return out.append('"').toString();
  }

  private static String names(Iterable<? extends IMetaObject> objects) {
  	java.util.List<String> names = new java.util.ArrayList<>();
  	for (IMetaObject object : objects) names.add(object.getName());
  	java.util.Collections.sort(names);
  	StringBuilder out = new StringBuilder("[");
  	for (int i = 0; i < names.size(); i++) out.append(i == 0 ? "" : ",").append(text(names.get(i)));
  	return out.append(']').toString();
  }

  private static String datatype(IDataType type) {
  	if (type == null) return "null";
  	return "{\"type\":" + text(type.getType().toString()) + ",\"dsl\":" + text(type.getDSLType())
  		+ ",\"object\":" + text(type.getObjectType()) + ",\"list\":" + type.isList()
  		+ ",\"mendix_object\":" + type.isMendixObject() + "}";
  }
JAVA
BODY = <<~'JAVA'.strip
  StringBuilder out = new StringBuilder("{\"objects\":[");
  		java.util.List<IMetaObject> objects = new java.util.ArrayList<>();
  		for (IMetaObject object : Core.getMetaObjects()) objects.add(object);
  		objects.sort(java.util.Comparator.comparing(IMetaObject::getName));
  		boolean first = true;
  		for (IMetaObject object : objects) {
  			if (!first) out.append(',');
  			first = false;
  			out.append("{\"name\":").append(text(object.getName()))
  				.append(",\"module\":").append(text(object.getModuleName()))
  				.append(",\"persistable\":").append(object.isPersistable())
  				.append(",\"supers\":").append(names(object.getSuperObjects()))
  				.append(",\"subs\":").append(names(object.getSubObjects()))
  				.append(",\"primitives\":[");
  			boolean firstMember = true;
  			for (IMetaPrimitive primitive : object.getMetaPrimitives()) {
  				if (!firstMember) out.append(',');
  				firstMember = false;
  				IDataType type = primitive.getType() == IMetaPrimitive.PrimitiveType.Enum
  					? Core.createDataType(object.getName(), primitive.getName())
  					: Core.createDataType(primitive.getType().toString());
  				out.append("{\"name\":").append(text(primitive.getName()))
  					.append(",\"type\":").append(text(primitive.getType().toString()))
  					.append(",\"length\":").append(primitive.getLength())
  					.append(",\"virtual\":").append(primitive.isVirtual())
  					.append(",\"datatype\":").append(datatype(type));
  				if (primitive.getType() == IMetaPrimitive.PrimitiveType.Enum) {
  					out.append(",\"enum\":[");
  					boolean firstValue = true;
  					for (IMetaEnumValue value : primitive.getEnumValues()) {
  						if (!firstValue) out.append(',');
  						firstValue = false;
  						out.append("{\"id\":").append(text(value.getIdentifier()))
  							.append(",\"caption\":").append(text(Core.getInternationalizedString("en_US", value.getI18NCaptionKey()))).append('}');
  					}
  					out.append(']');
  				}
  				out.append('}');
  			}
  			out.append("]}");
  		}
  		out.append("],\"associations\":[");
  		java.util.List<IMetaAssociation> associations = new java.util.ArrayList<>();
  		for (IMetaAssociation association : Core.getMetaAssociations()) associations.add(association);
  		associations.sort(java.util.Comparator.comparing((IMetaAssociation a) -> a.getName() + "/" + a.getParent().getName()));
  		first = true;
  		for (IMetaAssociation association : associations) {
  			if (!first) out.append(',');
  			first = false;
  			out.append("{\"name\":").append(text(association.getName()))
  				.append(",\"parent\":").append(text(association.getParent().getName()))
  				.append(",\"child\":").append(text(association.getChild().getName()))
  				.append(",\"type\":").append(text(association.getType().toString()))
  				.append(",\"owner\":").append(text(association.getOwner().toString())).append('}');
  		}
  		out.append("],\"microflows\":[");
  		java.util.List<String> microflows = new java.util.ArrayList<>(Core.getMicroflowNames());
  		java.util.Collections.sort(microflows);
  		first = true;
  		for (String name : microflows) {
  			if (!first) out.append(',');
  			first = false;
  			out.append("{\"name\":").append(text(name)).append(",\"parameters\":[");
  			boolean firstParameter = true;
  			for (java.util.Map.Entry<String, IDataType> entry : Core.getInputParameters(name).entrySet()) {
  				if (!firstParameter) out.append(',');
  				firstParameter = false;
  				out.append("{\"name\":").append(text(entry.getKey())).append(",\"datatype\":").append(datatype(entry.getValue())).append('}');
  			}
  			out.append("],\"return\":").append(datatype(Core.getReturnType(name))).append('}');
  		}
  		out.append("],\"languages\":[");
  		first = true;
  		for (IMendixObject language : Core.createXPathQuery("//System.Language").execute(getContext())) {
  			if (!first) out.append(',');
  			first = false;
  			out.append(text((String) language.getValue(getContext(), "Code")));
  		}
  		out.append("]}");
  		java.nio.file.Path path = java.nio.file.Paths.get(System.getProperty("java.io.tmpdir"), "mxrb-metamodel.json");
  		java.nio.file.Files.writeString(path, out.toString());
  		return path.toString();
JAVA

directory = File.join(File.dirname(output_path), 'javasource', 'views', 'actions')
FileUtils.mkdir_p(directory)
File.write(File.join(directory, 'DumpMetamodel.java'), java_action('DumpMetamodel', 'java.lang.String', nil, BODY))
