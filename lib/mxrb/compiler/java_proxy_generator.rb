# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module Compiler
    # Materializes the subset of Studio Pro generated Java proxies required by project sources.
    # Proxy syntax is intentionally kept together so generated Java remains auditable.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
    class JavaProxyGenerator
      include ModelValues

      TYPE_MAP = {
        'DomainModels$StringAttributeType' => 'java.lang.String',
        'DomainModels$HashStringAttributeType' => 'java.lang.String',
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
        @domain_units = @source.units_of('DomainModels$DomainModel')
        @entities = entity_index
      end

      def generate
        source_text = java_source_text
        requested = requested_entities(source_text)
        generated = requested.count { |name| write_entity(name) }
        generated += enumeration_units.count { |unit| referenced?(source_text, proxy_name(unit)) && write_enum(unit) }
        generated + constant_modules.count { |mod| constants_referenced?(source_text, mod) && write_constants(mod) }
      end

      private

      def java_source_text
        Dir.glob(File.join(@project_root, 'javasource', '**', '*.java')).sort.map { File.read(_1) }.join("\n")
      end

      def entity_index
        @domain_units.each_with_object({}) do |unit, index|
          array(unit.document['Entities']).each do |entity|
            index["#{unit.module_name}.#{entity['Name']}"] = [unit, entity]
          end
        end
      end

      def requested_entities(text)
        requested = @entities.keys.select { referenced?(text, java_proxy_name(_1)) }
        requested.each_with_object(requested.to_set) do |name, result|
          parent = generalization(@entities.fetch(name).last)
          result << parent if @entities.key?(parent)
        end.to_a
      end

      def referenced?(text, java_name)
        text.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(java_name)}(?![A-Za-z0-9_])/)
      end

      def java_proxy_name(qualified)
        mod, name = qualified.split('.', 2)
        "#{java_package(mod)}.proxies.#{name}"
      end

      def proxy_name(unit) = "#{java_package(unit.module_name)}.proxies.#{unit.document['Name']}"
      def java_package(mod) = mod.to_s.downcase

      def write_entity(qualified)
        unit, entity = @entities.fetch(qualified)
        path = proxy_path(unit.module_name, "#{entity['Name']}.java")
        write_missing(path, entity_source(unit, entity))
      end

      def entity_source(unit, entity) # rubocop:disable Metrics/MethodLength
        qualified = "#{unit.module_name}.#{entity['Name']}"
        java_name = java_proxy_name(qualified)
        parent = generalization(entity)
        local_parent = @entities.key?(parent) ? java_proxy_name(parent) : nil
        members = attributes(entity).map { _1['Name'] } + associations_for(unit, entity).map { _1['Name'] }
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

          public class #{entity['Name']} #{inheritance} {
            #{storage}
            public static final java.lang.String entityName = "#{qualified}";
            public enum MemberNames {
              #{members.map { |name| "#{name}(\"#{name}\")" }.join(",\n    ")};
              private final java.lang.String metaName;
              MemberNames(java.lang.String value) { metaName = value; }
              @java.lang.Override public java.lang.String toString() { return metaName; }
            }

            public #{entity['Name']}(com.mendix.systemwideinterfaces.core.IContext context) {
              this(context, com.mendix.core.Core.instantiate(context, entityName));
            }
            protected #{entity['Name']}(com.mendix.systemwideinterfaces.core.IContext context,
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
        array(unit.document['Associations']).select { identifier(_1['ParentPointer']) == id }
      end

      def association_methods(unit, association)
        return '' unless association['Type'] == 'ReferenceSet'

        name = association['Name']
        child = entity_by_id(association['ChildPointer'])
        child_type = if child
                       java_proxy_name("#{unit.module_name}.#{child['Name']}")
                     else
                       'com.mendix.systemwideinterfaces.core.IEntityProxy'
                     end
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

      def entity_by_id(id)
        wanted = identifier(id)
        @entities.values.map(&:last).find { identifier(_1['$ID']) == wanted }
      end

      def identifier(value)
        value.respond_to?(:data) ? value.data : value.to_s
      end

      def attributes(entity) = array(entity['Attributes'])
      def generalization(entity) = entity.dig('MaybeGeneralization', 'Generalization').to_s

      def enumeration_units = @source.units_of('Enumerations$Enumeration')

      def write_enum(unit)
        names = array(unit.document['Values']).map { _1['Name'] }
        source = <<~JAVA
          // Generated natively by mxrb from the MPR model.
          package #{java_package(unit.module_name)}.proxies;
          public enum #{unit.document['Name']} { #{names.join(', ')} }
        JAVA
        write_missing(proxy_path(unit.module_name, "#{unit.document['Name']}.java"), source)
      end

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
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
  end
end
