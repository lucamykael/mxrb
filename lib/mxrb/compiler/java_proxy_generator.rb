# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module Compiler
    # Materializes the subset of Studio Pro generated Java proxies required by project sources.
    # Proxy syntax is intentionally kept together so generated Java remains auditable.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class JavaProxyGenerator
      include ModelValues

      TYPE_MAP = {
        'DomainModels$StringAttributeType' => 'java.lang.String',
        'DomainModels$HashStringAttributeType' => 'java.lang.String',
        'DomainModels$HashedStringAttributeType' => 'java.lang.String',
        'DomainModels$IntegerAttributeType' => 'java.lang.Integer',
        'DomainModels$LongAttributeType' => 'java.lang.Long',
        'DomainModels$AutoNumberAttributeType' => 'java.lang.Long',
        'DomainModels$DecimalAttributeType' => 'java.math.BigDecimal',
        'DomainModels$BooleanAttributeType' => 'java.lang.Boolean',
        'DomainModels$DateTimeAttributeType' => 'java.util.Date',
        'DomainModels$BinaryAttributeType' => 'byte[]'
      }.freeze

      CONSTANT_TYPE_MAP = {
        'DataTypes$StringType' => 'java.lang.String', 'DataTypes$IntegerType' => 'java.lang.Long',
        'DataTypes$DecimalType' => 'java.math.BigDecimal', 'DataTypes$BooleanType' => 'java.lang.Boolean',
        'DataTypes$DateTimeType' => 'java.util.Date'
      }.freeze

      def initialize(mpr_path, project_root: File.dirname(File.expand_path(mpr_path)))
        @source = SourceModel.read(mpr_path)
        @project_root = File.expand_path(project_root)
        @system_seed = SystemModelSeed.for(@source.version)
        @domain_units = @source.units_of('DomainModels$DomainModel') + [system_domain_unit]
        @entities = entity_index
      end

      def generate
        generated = write_user_actions_registrar ? 1 : 0
        source_text = java_source_text
        generated += microflow_modules.count do |mod|
          microflows_referenced?(source_text, mod) && write_microflows(mod, source_text)
        end
        source_text = java_source_text if generated.positive?
        requested = requested_entities(source_text)
        entity_count = requested.count { |name| write_entity(name) }
        generated += entity_count
        source_text = java_source_text if entity_count.positive?
        generated += enumeration_units.count { |unit| referenced?(source_text, proxy_name(unit)) && write_enum(unit) }
        generated += constant_modules.count { |mod| constants_referenced?(source_text, mod) && write_constants(mod) }
        generated
      end

      private

      def java_source_text
        Dir.glob(File.join(@project_root, 'javasource', '**', '*.java')).sort.map { File.read(_1) }.join("\n")
      end

      def write_user_actions_registrar
        classes = user_action_classes
        return false if classes.empty?

        path = File.join(@project_root, 'javasource', 'system', 'UserActionsRegistrar.java')
        write_missing(path, user_actions_registrar_source(classes))
      end

      def user_action_classes
        @source.units_of('JavaActions$JavaAction').filter_map do |unit|
          name = document_name(unit.document).to_s
          package_name = java_package(unit.module_name)
          source = File.join(@project_root, 'javasource', package_name, 'actions', "#{name}.java")
          "#{package_name}.actions.#{name}" if !name.empty? && File.file?(source)
        end.sort.uniq
      end

      def user_actions_registrar_source(classes)
        registrations = classes.map do |class_name|
          "    registrator.registerUserAction(#{class_name}.class);"
        end.join("\n")
        <<~JAVA
          // Generated natively by mxrb from Java action documents and sources.
          package system;

          public class UserActionsRegistrar {
            public void registerActions(com.mendix.core.actionmanagement.IActionRegistrator registrator) {
          #{registrations}
            }
          }
        JAVA
      end

      def entity_index
        @domain_units.each_with_object({}) do |unit, index|
          array(unit.document['Entities']).each do |entity|
            index[entity_qualified_name(unit, entity)] = [unit, entity]
          end
        end
      end

      def system_domain_unit
        document = @system_seed.domain_document
        SourceModel::Unit.new(
          id: identifier(document['$ID']), container_id: SystemModelSeed::MODULE_ID,
          containment: 'DomainModel', document:, module_name: 'System'
        )
      end

      def entity_qualified_name(unit, entity)
        entity['QualifiedName'] || "#{unit.module_name}.#{entity.fetch('Name')}"
      end

      def entity_name(entity) = entity['Name'] || entity['UnqualifiedName']

      def requested_entities(text)
        result = @entities.keys.select { referenced?(text, java_proxy_name(_1)) }.to_set
        loop do
          before = result.length
          result.to_a.each { add_entity_dependencies(_1, result) }
          break if result.length == before
        end
        result.to_a
      end

      def add_entity_dependencies(name, result)
        unit, entity = @entities.fetch(name)
        parent = generalization(entity)
        result << parent if @entities.key?(parent)
        associations_for(unit, entity).each do |association|
          child = association_child_qualified(unit, association)
          result << child if @entities.key?(child)
        end
      end

      def referenced?(text, java_name)
        text.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(java_name)}(?![A-Za-z0-9_])/)
      end

      def java_proxy_name(qualified)
        mod, name = qualified.split('.', 2)
        "#{java_package(mod)}.proxies.#{name}"
      end

      def proxy_name(unit) = "#{java_package(unit.module_name)}.proxies.#{document_name(unit.document)}"
      def java_package(mod) = mod.to_s.downcase

      def write_entity(qualified)
        unit, entity = @entities.fetch(qualified)
        path = proxy_path(unit.module_name, "#{entity_name(entity)}.java")
        write_missing(path, entity_source(unit, entity))
      end

      def entity_source(unit, entity) # rubocop:disable Metrics/MethodLength
        name = entity_name(entity)
        qualified = entity_qualified_name(unit, entity)
        java_name = java_proxy_name(qualified)
        parent = generalization(entity)
        local_parent = @entities.key?(parent) ? java_proxy_name(parent) : nil
        members = attributes(entity).map { [_1['Name'], _1['Name']] }
        members += associations_for(unit, entity).map do |association|
          [association_name(association), association_qualified_name(unit, association)]
        end
        inheritance = if local_parent
                        "extends #{local_parent}"
                      else
                        'implements com.mendix.systemwideinterfaces.core.IEntityProxy'
                      end
        storage = local_parent ? '' : <<~JAVA
          private final com.mendix.systemwideinterfaces.core.IMendixObject mendixObject;
          private final com.mendix.systemwideinterfaces.core.IContext context;
        JAVA
        constructor_body = local_parent ? 'super(context, mendixObject);' : root_constructor_body
        accessors = attributes(entity).map { attribute_methods(unit, _1) }.join("\n")
        accessors += associations_for(unit, entity).map { association_methods(unit, _1) }.join("\n")
        base_methods = local_parent ? '' : base_entity_methods
        <<~JAVA
          // Generated natively by mxrb from the MPR model.
          package #{java_package(unit.module_name)}.proxies;

          public class #{name} #{inheritance} {
            #{storage}
            public static final java.lang.String entityName = "#{qualified}";
            public enum MemberNames {
              #{members.map { |member, meta| "#{member}(\"#{meta}\")" }.join(",\n    ")};
              private final java.lang.String metaName;
              MemberNames(java.lang.String value) { metaName = value; }
              @java.lang.Override public java.lang.String toString() { return metaName; }
            }

            public #{name}(com.mendix.systemwideinterfaces.core.IContext context) {
              this(context, com.mendix.core.Core.instantiate(context, entityName));
            }
            protected #{name}(com.mendix.systemwideinterfaces.core.IContext context,
                com.mendix.systemwideinterfaces.core.IMendixObject mendixObject) {
              #{constructor_body}
            }
            public static #{java_name} initialize(com.mendix.systemwideinterfaces.core.IContext context,
                com.mendix.systemwideinterfaces.core.IMendixObject mendixObject) {
              return new #{java_name}(context, mendixObject);
            }
            public static #{java_name} load(com.mendix.systemwideinterfaces.core.IContext context,
                com.mendix.systemwideinterfaces.core.IMendixIdentifier id) throws com.mendix.core.CoreException {
              return initialize(context, com.mendix.core.Core.retrieveId(context, id));
            }
          #{accessors}
          #{base_methods}
            public static java.lang.String getType() { return entityName; }
          }
        JAVA
      end # rubocop:enable Metrics/MethodLength

      def root_constructor_body
        <<~JAVA.chomp
          if (mendixObject == null)
            throw new java.lang.IllegalArgumentException("The given object cannot be null.");
          this.mendixObject = mendixObject;
          this.context = context;
        JAVA
      end

      def base_entity_methods
        <<~JAVA
          @java.lang.Override public com.mendix.systemwideinterfaces.core.IMendixObject getMendixObject() { return mendixObject; }
          public com.mendix.systemwideinterfaces.core.IContext getContext() { return context; }
          @java.lang.Override public boolean equals(Object other) {
            return other == this || (other != null && getClass().equals(other.getClass()) &&
              mendixObject.equals(((com.mendix.systemwideinterfaces.core.IEntityProxy) other).getMendixObject()));
          }
          @java.lang.Override public int hashCode() { return mendixObject.hashCode(); }
        JAVA
      end

      def attribute_methods(unit, attribute)
        name = attribute['Name']
        type = attribute['NewType'] || attribute['Type'] || {}
        java_type = attribute_java_type(unit, type)
        read = if type['$Type'] == 'DomainModels$EnumerationAttributeType'
                 enum_attribute_reader(name, java_type)
               else
                 "return (#{java_type}) getMendixObject().getValue(context, MemberNames.#{name}.toString());"
               end
        value = if type['$Type'] == 'DomainModels$EnumerationAttributeType'
                  'value == null ? null : value.toString()'
                else
                  'value'
                end
        <<~JAVA
          public final #{java_type} get#{name}() { return get#{name}(getContext()); }
          public final #{java_type} get#{name}(com.mendix.systemwideinterfaces.core.IContext context) {
            #{read}
          }
          public final void set#{name}(#{java_type} value) { set#{name}(getContext(), value); }
          public final void set#{name}(com.mendix.systemwideinterfaces.core.IContext context, #{java_type} value) {
            getMendixObject().setValue(context, MemberNames.#{name}.toString(), #{value});
          }
        JAVA
      end

      def enum_attribute_reader(name, java_type)
        "Object value = getMendixObject().getValue(context, MemberNames.#{name}.toString());\n" \
          "      return value == null ? null : #{java_type}.valueOf((java.lang.String) value);"
      end

      def attribute_java_type(unit, type)
        unless type['$Type'] == 'DomainModels$EnumerationAttributeType'
          return TYPE_MAP.fetch(type['$Type'],
                                'java.lang.Object')
        end

        reference = type['Enumeration'].to_s
        reference = "#{unit.module_name}.#{reference}" unless reference.include?('.')
        java_proxy_name(reference)
      end

      def associations_for(unit, entity)
        id = identifier(entity['$ID'])
        associations = array(unit.document['Associations']) + array(unit.document['CrossAssociations'])
        associations.select { identifier(_1['ParentPointer']) == id }
      end

      def association_methods(unit, association)
        name = association_name(association)
        child_type = association_child_type(unit, association)
        return reference_methods(name, child_type) if association['Type'] == 'Reference'
        return '' unless association['Type'] == 'ReferenceSet'

        <<~JAVA
          public final java.util.List<#{child_type}> get#{name}() throws com.mendix.core.CoreException { return get#{name}(getContext()); }
          public final java.util.List<#{child_type}> get#{name}(com.mendix.systemwideinterfaces.core.IContext context) throws com.mendix.core.CoreException {
            java.util.List<com.mendix.systemwideinterfaces.core.IMendixIdentifier> ids = getMendixObject().getValue(context, MemberNames.#{name}.toString());
            if (ids == null) return java.util.Collections.emptyList();
            java.util.List<#{child_type}> result = new java.util.ArrayList<>();
            for (com.mendix.systemwideinterfaces.core.IMendixIdentifier id : ids) result.add(#{child_type}.load(context, id));
            return result;
          }
          public final void set#{name}(java.util.List<#{child_type}> values) { set#{name}(getContext(), values); }
          public final void set#{name}(com.mendix.systemwideinterfaces.core.IContext context, java.util.List<#{child_type}> values) {
            java.util.List<com.mendix.systemwideinterfaces.core.IMendixIdentifier> ids = values == null ? null : values.stream()
              .map(value -> value.getMendixObject().getId()).collect(java.util.stream.Collectors.toList());
            getMendixObject().setValue(context, MemberNames.#{name}.toString(), ids);
          }
        JAVA
      end

      def association_name(association)
        association['Name'] || association['UnqualifiedName'] || association['QualifiedName'].to_s.split('.').last
      end

      def association_qualified_name(unit, association)
        association['QualifiedName'] || "#{unit.module_name}.#{association_name(association)}"
      end

      def association_child_type(unit, association)
        qualified = association_child_qualified(unit, association)
        unless qualified.empty?
          return java_proxy_name(qualified) if @entities.key?(qualified)

          return 'com.mendix.systemwideinterfaces.core.IEntityProxy'
        end

        'com.mendix.systemwideinterfaces.core.IEntityProxy'
      end

      def association_child_qualified(unit, association)
        qualified = association['Child'].to_s
        return qualified unless qualified.empty?

        child = entity_by_id(association['ChildPointer'])
        child ? entity_qualified_name(unit, child) : ''
      end

      def reference_methods(name, child_type)
        <<~JAVA
          public final #{child_type} get#{name}() throws com.mendix.core.CoreException { return get#{name}(getContext()); }
          public final #{child_type} get#{name}(com.mendix.systemwideinterfaces.core.IContext context) throws com.mendix.core.CoreException {
            com.mendix.systemwideinterfaces.core.IMendixIdentifier id = getMendixObject().getValue(context, MemberNames.#{name}.toString());
            return id == null ? null : #{child_type}.load(context, id);
          }
          public final void set#{name}(#{child_type} value) { set#{name}(getContext(), value); }
          public final void set#{name}(com.mendix.systemwideinterfaces.core.IContext context, #{child_type} value) {
            getMendixObject().setValue(context, MemberNames.#{name}.toString(), value == null ? null : value.getMendixObject().getId());
          }
        JAVA
      end

      def entity_by_id(id)
        wanted = identifier(id)
        @entities.values.map(&:last).find { identifier(_1['$ID']) == wanted }
      end

      def identifier(value)
        value.respond_to?(:data) ? value.data : value.to_s
      end

      def attributes(entity) = array(entity['Attributes'])
      def generalization(entity) = entity.dig('MaybeGeneralization', 'Generalization').to_s

      def enumeration_units
        source_units = @source.units_of('Enumerations$Enumeration')
        system_units = @system_seed.package.documents.filter_map do |document|
          next unless document['$Type'] == 'Enumerations$Enumeration'

          SourceModel::Unit.new(
            id: identifier(document['$ID']), container_id: SystemModelSeed::MODULE_ID,
            containment: 'AllDocuments', document:, module_name: 'System'
          )
        end
        source_units + system_units
      end

      def write_enum(unit)
        names = array(unit.document['Values']).map { _1['Name'] }
        name = document_name(unit.document)
        source = <<~JAVA
          // Generated natively by mxrb from the MPR model.
          package #{java_package(unit.module_name)}.proxies;
          public enum #{name} { #{names.join(', ')} }
        JAVA
        write_missing(proxy_path(unit.module_name, "#{name}.java"), source)
      end

      def document_name(document) = document['Name'] || document['UnqualifiedName']

      def constant_modules = @source.units_of('Constants$Constant').map(&:module_name).uniq

      def constants_referenced?(text, mod)
        referenced?(text, "#{java_package(mod)}.proxies.constants.Constants")
      end

      def write_constants(mod)
        units = @source.units_of('Constants$Constant').select { _1.module_name == mod }
        methods = units.map do |unit|
          type = CONSTANT_TYPE_MAP.fetch(unit.document.dig('Type', '$Type'), 'java.lang.Object')
          name = unit.document['Name']
          "public static #{type} get#{name}() { return (#{type}) " \
            "com.mendix.core.Core.getConfiguration().getConstantValue(\"#{mod}.#{name}\"); }"
        end.join("\n  ")
        source = <<~JAVA
          // Generated natively by mxrb from the MPR model.
          package #{java_package(mod)}.proxies.constants;
          public final class Constants {
            private Constants() {}
            #{methods}
          }
        JAVA
        write_missing(proxy_path(mod, 'constants', 'Constants.java'), source)
      end

      def microflow_modules = @source.units_of('Microflows$Microflow').map(&:module_name).uniq

      def microflows_referenced?(text, mod)
        referenced?(text, "#{java_package(mod)}.proxies.microflows.Microflows")
      end

      def write_microflows(mod, text)
        units = @source.units_of('Microflows$Microflow').select { _1.module_name == mod }
        selected = units.select { |unit| referenced_microflow?(text, unit.document['Name']) }
        return false if selected.empty?

        methods = selected.map { microflow_method(_1) }.join("\n")
        source = <<~JAVA
          // Generated natively by mxrb from the MPR model.
          package #{java_package(mod)}.proxies.microflows;
          public final class Microflows {
            private Microflows() {}
          #{methods}
          }
        JAVA
        write_missing(proxy_path(mod, 'microflows', 'Microflows.java'), source)
      end

      def referenced_microflow?(text, name)
        method = lower_camel(name)
        text.match?(/\bMicroflows\.#{Regexp.escape(method)}\b/)
      end

      def microflow_method(unit)
        parameters = microflow_parameters(unit.document)
        declarations = parameters.map do |parameter|
          "#{java_data_type(parameter['VariableType'])} _#{lower_camel(parameter['Name'])}"
        end
        arguments = parameters.map do |parameter|
          ".withParam(\"#{parameter['Name']}\", _#{lower_camel(parameter['Name'])})"
        end.join
        return_type = java_data_type(unit.document['MicroflowReturnType'], return_type: true)
        result = microflow_result(unit.document['MicroflowReturnType'])
        <<~JAVA
          public static #{return_type} #{lower_camel(unit.document['Name'])}(
              com.mendix.systemwideinterfaces.core.IContext context#{declarations.empty? ? '' : ",\n        #{declarations.join(",\n        ")}"}) {
            Object result = com.mendix.core.Core.microflowCall("#{unit.module_name}.#{unit.document['Name']}")#{arguments}.execute(context);
            #{result}
          }
        JAVA
      end

      def microflow_parameters(document)
        array(document.dig('ObjectCollection', 'Objects')).select do |object|
          object['$Type'] == 'Microflows$MicroflowParameter'
        end
      end

      def java_data_type(type, return_type: false)
        case type&.fetch('$Type', nil)
        when 'DataTypes$BooleanType' then return_type ? 'boolean' : 'java.lang.Boolean'
        when 'DataTypes$IntegerType', 'DataTypes$LongType' then 'java.lang.Long'
        when 'DataTypes$DecimalType' then 'java.math.BigDecimal'
        when 'DataTypes$DateTimeType' then 'java.util.Date'
        when 'DataTypes$StringType' then 'java.lang.String'
        when 'DataTypes$ObjectType' then java_proxy_name(type['Entity'])
        when 'DataTypes$VoidType', nil then 'void'
        else 'java.lang.Object'
        end
      end

      def microflow_result(type)
        case type&.fetch('$Type', nil)
        when 'DataTypes$BooleanType' then 'return (boolean) result;'
        when 'DataTypes$ObjectType'
          proxy = java_proxy_name(type['Entity'])
          "return result == null ? null : #{proxy}.initialize(context, " \
            '(com.mendix.systemwideinterfaces.core.IMendixObject) result);'
        when 'DataTypes$VoidType', nil then 'return;'
        else "return (#{java_data_type(type, return_type: true)}) result;"
        end
      end

      def lower_camel(value)
        value.to_s.sub(/\A./, &:downcase)
      end

      def proxy_path(mod, *parts)
        File.join(@project_root, 'javasource', java_package(mod), 'proxies', *parts)
      end

      def write_missing(path, contents)
        return false if File.exist?(path)

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
        true
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
