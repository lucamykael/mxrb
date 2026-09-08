# frozen_string_literal: true

require 'securerandom'
require_relative '../io/bson_codec'
require_relative 'storage_naming'
require_relative 'source_emitter'
require_relative '../pluggable/mpr_codec'

module Mxrb
  module Forms
    class MprCodecError < StandardError; end
    class UnsupportedStoragePropertyError < MprCodecError; end
    class UnresolvedStorageReferenceError < MprCodecError; end

    # Strict boundary between physical BSON documents and the typed Ruby
    # model. Unknown fields fail with their path; no native fragment is kept.
    class MprCodec # rubocop:disable Metrics/ClassLength
      INTERNAL_PREFIXES = %w[Forms$ Pages$].freeze
      COMPANION_FIELDS = %w[$ID $Type ExpressionModel].freeze
      COLLECTION_MARKERS = {
        %w[Appearance designProperties] => 3,
        %w[ClientTemplate parameters] => 2,
        %w[ConditionallyVisibleWidget moduleRoles] => 1,
        %w[ControlBar items] => 3,
        %w[DataView footerWidgets] => 2,
        %w[DataView widgets] => 2,
        %w[MicroflowSettings outputMappings] => 3,
        %w[Page parameters] => 3,
        %w[TabContainer tabPages] => 3,
        %w[WidgetValidation conditions] => 2
      }.transform_keys(&:freeze).freeze
      OBSOLETE_DEFAULT_FIELDS = {
        'DatePicker' => { 'AutoFocus' => false }
      }.freeze
      private_constant :COLLECTION_MARKERS

      def initialize(catalog: Catalog.for('11.12.1'), reference_decoder: nil,
                     reference_encoder: nil, pluggable_catalog: Pluggable::Catalog.default)
        @catalog = catalog
        @reference_decoder = reference_decoder
        @reference_encoder = reference_encoder
        @pluggable_codec = Pluggable::MprCodec.new(forms_codec: self, catalog: pluggable_catalog)
      end

      def decode(document)
        raise TypeError, 'MPR Forms document must be a Hash' unless document.is_a?(Hash)

        previous = @local_decode_references
        @local_decode_references = storage_reference_names(document)
        decode_embedded(document)
      ensure
        @local_decode_references = previous
      end

      def encode(node, baseline: nil)
        unless node.is_a?(Node) || node.is_a?(Pluggable::Node)
          raise TypeError, 'MPR Forms value must be a typed widget node'
        end

        previous_ids = @node_ids
        previous_references = @local_encode_references
        previous_baselines = @pluggable_baselines
        @pluggable_baselines = index_pluggable_baselines(baseline)
        prepare_node_ids(node)
        encode_embedded(node)
      ensure
        @node_ids = previous_ids
        @local_encode_references = previous_references
        @pluggable_baselines = previous_baselines
      end

      # Nested pluggable values share the root's semantic reference maps.
      def decode_embedded(document, path: '$')
        return pluggable_codec.decode(document, path:) if document['$Type'] == 'CustomWidgets$CustomWidget'

        decode_node(document, path:)
      end

      def encode_embedded(node, path: '$')
        return pluggable_codec.encode(node, path:) if node.is_a?(Pluggable::Node)

        encode_node(node, path:)
      end

      def register_pluggable_type(document)
        pluggable_codec.register_type(document)
      end

      def decode_attribute_reference_value(value, path: '$')
        decode_attribute_reference(value, path:)
      end

      def encode_attribute_reference_value(value)
        encode_attribute_reference(AttributeReference.coerce(value))
      end

      def decode_entity_reference_value(value, path: '$')
        decode_entity_reference(value, path:)
      end

      def encode_entity_reference_value(value)
        encode_entity_reference(EntityReference.coerce(value))
      end

      def pluggable_baseline_for(node)
        key = [node.widget_type.id.to_s, node.identifier.to_s]
        @pluggable_baselines&.fetch(key, nil)&.shift
      end

      private

      attr_reader :catalog, :reference_decoder, :reference_encoder, :pluggable_codec

      def index_pluggable_baselines(document)
        index = Hash.new { |entries, key| entries[key] = [] }
        walk = lambda do |value|
          case value
          when Hash
            if value['$Type'] == 'CustomWidgets$CustomWidget'
              key = [value.dig('Type', 'WidgetId').to_s, value['Name'].to_s]
              index[key] << value
            end
            value.each_value { walk.call(_1) }
          when Array
            value.each { walk.call(_1) unless _1.is_a?(Integer) }
          end
        end
        walk.call(document) if document
        index
      end

      def decode_node(document, path:) # rubocop:disable Metrics/AbcSize,Metrics/BlockLength,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        return pluggable_codec.decode(document, path:) if document['$Type'] == 'CustomWidgets$CustomWidget'

        type_name = internal_type_name(document.fetch('$Type'))
        schema_type = catalog.fetch_type(type_name)
        if schema_type.name == 'DesignPropertyValue' && !document.key?('Value')
          return decode_legacy_design_property(document, path:)
        end

        node = Node.new(schema_type.name, catalog:)
        consumed = COMPANION_FIELDS.dup
        consume_empty_legacy_fields!(schema_type, document, consumed, path:)
        consume_obsolete_defaults!(schema_type, document, consumed, path:)
        schema_type.all_properties.each do |property|
          if legacy_attribute_path?(property, document)
            consumed << 'AttributePath'
            unless document.key?('AttributeRef')
              node.set(property.name, AttributeReference.coerce(document['AttributePath']))
              next
            end
          end
          if legacy_label_text?(property, document)
            consumed << 'LabelText'
            unless document.key?('LabelTemplate')
              node.set(property.name, legacy_client_template(document['LabelText'], path:))
              next
            end
          end
          if legacy_flat_appearance_fields?(property, document)
            consumed.concat(%w[Class Style])
            unless document.key?('Appearance')
              node.set(property.name, decode_flat_appearance(document))
              next
            end
          end
          storage = StorageNaming.candidates(property).find { document.key?(_1) } ||
                    StorageNaming.resolve(property).name
          if legacy_source_variable?(schema_type, property, document)
            consumed << 'PageParameter'
            node.set(property.name, decode_legacy_source_variable(document['PageParameter']))
            next
          end
          next unless document.key?(storage)

          consumed << storage
          value = decode_property(property, document[storage], path: "#{path}.#{storage}")
          node.set(property.name, value)
        end
        unknown = document.keys.map(&:to_s) - consumed
        unless unknown.empty?
          raise UnsupportedStoragePropertyError,
                "unmapped #{schema_type.name} storage field(s) at #{path}: #{unknown.sort.join(', ')}"
        end
        node
      end

      def legacy_attribute_path?(property, document)
        property.name == 'attributeRef' && document.key?('AttributePath')
      end

      def legacy_label_text?(property, document)
        property.name == 'labelTemplate' && document.key?('LabelText')
      end

      def legacy_client_template(value, path:)
        Node.new('ClientTemplate', catalog:).tap do |template|
          template.template decode_text(value, path: "#{path}.LabelText")
          template.fallback Text.coerce([])
          template.set(:parameters, [])
        end
      end

      def legacy_flat_appearance_fields?(property, document)
        property.name == 'appearance' &&
          (document.key?('Class') || document.key?('Style'))
      end

      def decode_flat_appearance(document)
        Node.new('Appearance', catalog:).tap do |appearance|
          appearance.css_class document.fetch('Class', '').to_s
          appearance.style document.fetch('Style', '').to_s
          appearance.set(:design_properties, [])
          appearance.dynamic_classes ''
        end
      end

      def consume_empty_legacy_fields!(schema_type, document, consumed, path:)
        return unless schema_type.name == 'Snippet' && document.key?('Entity')
        unless document['Entity'].to_s.empty?
          raise MprCodecError, "legacy Snippet.Entity at #{path} requires a typed parameter migration"
        end

        consumed << 'Entity'
      end

      def consume_obsolete_defaults!(schema_type, document, consumed, path:)
        OBSOLETE_DEFAULT_FIELDS.fetch(schema_type.name, {}).each do |field, default|
          next unless document.key?(field)
          unless document[field] == default
            raise MprCodecError, "non-default obsolete #{schema_type.name}.#{field} at #{path}"
          end

          consumed << field
        end
      end

      def decode_property(property, value, path:)
        return nil if value.nil? && property.optional?

        if property.many?
          return IO::BsonCodec.parse_array(value).fetch(:items).map.with_index do |item, index|
            decode_one(property, item, path: "#{path}[#{index}]")
          end
        end
        decode_one(property, value, path:)
      end

      def decode_one(property, value, path:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
        return decode_reference(property, value, path:) if property.reference?

        target = catalog.type(property.type_name)
        return decode_blob(value, path:) if property.type_name == 'blob'
        return value if %w[string integer boolean].include?(property.type_name)
        return decode_size(value, path:) if property.type_name == 'size'
        return legacy_enum_value(property, value) if target&.enum?
        return decode_legacy_placeholder(value, path:) if legacy_placeholder?(property, value)
        return decode_node(value, path:) if target&.element?

        decode_external(property.type_name, value, path:)
      end

      def decode_external(type, value, path:) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/MethodLength
        case type
        when 'Text' then decode_text(value, path:)
        when 'Expression' then Expression.coerce(value)
        when 'AttributeReference' then decode_attribute_reference(value, path:)
        when 'EntityReference' then decode_entity_reference(value, path:)
        when 'DataType' then decode_data_type(value, path:)
        when 'Condition' then decode_condition(value, path:)
        when 'TextTemplate' then decode_text_template(value, path:)
        when 'XPathConstraint' then decode_xpath_constraint(value)
        else raise MprCodecError, "unsupported external Forms type #{type} at #{path}"
        end
      end

      def decode_xpath_constraint(value)
        return XPathConstraint.coerce(value) unless value.is_a?(Array)

        clauses = IO::BsonCodec.parse_array(value).fetch(:items).map do |item|
          next item unless item.is_a?(Hash)
          next item.fetch('XPathConstraint') if item.key?('XPathConstraint')

          type = item.fetch('$Type', 'unknown')
          raise MprCodecError,
                "structured legacy database constraint #{type} cannot be converted " \
                'to XPath without entity and attribute type context'
        end
        XPathConstraint.coerce(clauses)
      end

      def decode_attribute_reference(value, path:)
        return AttributeReference.coerce(value) unless value.is_a?(Hash)
        unless value['$Type'].to_s.end_with?('$AttributeRef')
          raise MprCodecError, "invalid AttributeReference at #{path}"
        end

        entity = value['EntityRef'] && decode_entity_reference(value['EntityRef'], path: "#{path}.EntityRef")
        AttributeReference.new(value.fetch('Attribute', ''), entity)
      end

      def decode_entity_reference(value, path:)
        return EntityReference.coerce(value) unless value.is_a?(Hash)

        case value['$Type'].to_s
        when /\$DirectEntityRef\z/
          EntityReference.direct(value.fetch('Entity', ''))
        when /\$IndirectEntityRef\z/
          steps = IO::BsonCodec.parse_array(value['Steps']).fetch(:items).map do |step|
            EntityPathStep.to(step.fetch('Association', ''), step.fetch('DestinationEntity', ''))
          end
          EntityReference.through(*steps)
        else
          raise MprCodecError, "invalid EntityReference at #{path}"
        end
      end

      def decode_condition(value, path:)
        return Condition.coerce(value) unless value.is_a?(Hash)
        unless value['$Type'].to_s.end_with?('$Condition')
          raise MprCodecError, "invalid Condition at #{path}"
        end

        Condition.when_value(value.fetch('AttributeValue', ''), visible: value['EditableVisible'])
      end

      def decode_text(value, path:)
        unless value.is_a?(Hash) && value['$Type'].to_s.end_with?('$Text')
          raise MprCodecError, "invalid Text at #{path}"
        end

        translations = IO::BsonCodec.parse_array(value['Items']).fetch(:items).map do |item|
          Translation.new(item['LanguageCode']&.to_s, item.fetch('Text', '').to_s)
        end
        Text.coerce(translations)
      end

      def decode_text_template(value, path:)
        raise MprCodecError, "invalid TextTemplate at #{path}" unless value.is_a?(Hash)

        text = decode_text(value.fetch('Text'), path: "#{path}.Text")
        parameters = IO::BsonCodec.parse_array(value['Parameters']).fetch(:items).map do |item|
          item.fetch('Expression', '').to_s
        end
        TextTemplate.build(text, parameters:)
      end

      def decode_size(value, path:)
        raise MprCodecError, "invalid size at #{path}" unless value.is_a?(Hash)

        Size.new(value.fetch('Width') { value.fetch('width') }, value.fetch('Height') { value.fetch('height') })
      end

      def decode_blob(value, path:)
        return BinaryAsset.from_bytes(value.data, subtype: value.type) if value.is_a?(BSON::Binary)
        return BinaryAsset.from_bytes(value) if value.is_a?(String)

        raise MprCodecError, "invalid binary asset at #{path}"
      end

      def decode_reference(property, value, path:)
        if property.reference == :by_id
          identifier = IO::BsonCodec.extract_id(value)
          return nil if identifier == '00000000-0000-0000-0000-000000000000'

          local = @local_decode_references&.fetch(identifier, nil)
          value = local if local
          unless local || reference_decoder
            raise UnresolvedStorageReferenceError, "by-id reference at #{path} requires a semantic resolver"
          end

          value = reference_decoder.call(value, path) unless local
        end
        Reference.to(value, kind: property.reference)
      end

      def reference_path(value, key)
        return value.to_s unless value.is_a?(Hash)

        value[key] || value["#{key}Path"] || ''
      end

      def external_type_name(value)
        return value.to_s unless value.is_a?(Hash)

        value.fetch('$Type', '').to_s.split('$').last.to_s.delete_suffix('Type')
      end

      def decode_data_type(value, path:)
        unless value.is_a?(Hash) && value['$Type'].to_s.start_with?('DataTypes$')
          return DataType.coerce(value)
        end

        name = external_type_name(value)
        target_field = { 'Object' => 'Entity', 'List' => 'Entity', 'Enumeration' => 'Enumeration' }[name]
        known = %w[$ID $Type]
        known << target_field if target_field
        unknown = value.keys.map(&:to_s) - known
        unless unknown.empty?
          raise MprCodecError, "unsupported DataType field(s) at #{path}: #{unknown.sort.join(', ')}"
        end

        DataType.build(name, target_field && value[target_field])
      end

      def internal_type_name(storage_type)
        prefix = INTERNAL_PREFIXES.find { storage_type.to_s.start_with?(_1) }
        raise MprCodecError, "not a Forms storage type: #{storage_type.inspect}" unless prefix

        StorageNaming.schema_type_name(storage_type.to_s.delete_prefix(prefix))
      end

      def legacy_placeholder?(property, value)
        property.name == 'placeholderTemplate' && value.is_a?(Hash) &&
          value['$Type'].to_s.end_with?('$Text')
      end

      def decode_legacy_placeholder(value, path:)
        Node.new('ClientTemplate', catalog:).tap do |template|
          template.template decode_text(value, path:)
          template.fallback Text.coerce([])
          template.set(:parameters, [])
        end
      end

      def legacy_enum_value(property, value)
        return value unless value.equal?(true) || value.equal?(false)
        return value ? 'Always' : 'Never' if property.type_name == 'EditableEnum'

        value
      end

      def legacy_source_variable?(schema_type, property, document)
        schema_type.name == 'DataViewSource' && property.name == 'sourceVariable' &&
          !document.key?('SourceVariable') && document.key?('PageParameter')
      end

      def decode_legacy_source_variable(name)
        Node.new('PageVariable', catalog:).tap do |variable|
          variable.page_parameter name.to_s unless name.to_s.empty?
          variable.use_all_pages false
          variable.sub_key ''
        end
      end

      def decode_legacy_design_property(document, path:) # rubocop:disable Metrics/MethodLength
        node = Node.new('DesignPropertyValue', catalog:)
        node.key document.fetch('Key', '')
        value_type = case document.fetch('Type', '')
                     when 'Toggle' then 'ToggleDesignPropertyValue'
                     when 'DropDown' then 'OptionDesignPropertyValue'
                     when 'Custom' then 'CustomDesignPropertyValue'
                     else raise MprCodecError, "unsupported design property type at #{path}"
                     end
        value = Node.new(value_type, catalog:)
        value.option document.fetch('StringValue', '') if value_type == 'OptionDesignPropertyValue'
        value.value document.fetch('StringValue', '') if value_type == 'CustomDesignPropertyValue'
        node.value value
        node
      end

      def encode_node(node, path:) # rubocop:disable Metrics/MethodLength
        document = {
          '$ID' => node_identifier(node),
          '$Type' => "Forms$#{storage_type_name(node)}"
        }
        node.assignments.each do |assignment|
          property = assignment.property
          storage = storage_property_name(property)
          document[storage] = encode_property(property, assignment.value, path: "#{path}.#{storage}")
          add_expression_companion(document, property, storage) if property.type_name == 'Expression'
        end
        document
      end

      def encode_property(property, value, path:)
        if property.many?
          items = value.map.with_index do |item, index|
            encode_one(property, item, path: "#{path}[#{index}]")
          end
          return IO::BsonCodec.build_array(items, marker: collection_marker(property))
        end
        return encode_legacy_placeholder(value, path:) if legacy_placeholder_node?(property, value)

        encode_one(property, value, path:)
      end

      def storage_type_name(node)
        StorageNaming.storage_type_name(node.schema_type.name)
      end

      def storage_property_name(property)
        StorageNaming.resolve(property).name
      end

      def legacy_placeholder_node?(property, value)
        property.name == 'placeholderTemplate' && value.is_a?(Node) &&
          value.schema_type.name == 'ClientTemplate'
      end

      def encode_legacy_placeholder(value, **_options)
        encode_text(value.fetch(:template) || Text.coerce([]))
      end

      def encode_one(_property, value, path:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return nil if value.nil?
        return encode_reference(value, path:) if value.is_a?(Reference)
        return value.to_s if value.is_a?(EnumValue)
        return pluggable_codec.encode(value, path:) if value.is_a?(Pluggable::Node)
        return encode_node(value, path:) if value.is_a?(Node)
        return encode_text(value) if value.is_a?(Text)
        return encode_text_template(value, path:) if value.is_a?(TextTemplate)
        return encode_attribute_reference(value) if value.is_a?(AttributeReference)
        return encode_entity_reference(value) if value.is_a?(EntityReference)
        return encode_data_type(value) if value.is_a?(DataType)
        return encode_condition(value) if value.is_a?(Condition)
        return BSON::Binary.new(value.bytes, value.subtype) if value.is_a?(BinaryAsset)
        return { 'Width' => value.width, 'Height' => value.height } if value.is_a?(Size)
        return value.to_s if value.respond_to?(:to_s) && Node::EXTERNAL_VALUES.value?(value.class)

        value
      end

      def encode_attribute_reference(reference)
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$AttributeRef',
          'Attribute' => reference.attribute,
          'EntityRef' => reference.entity_reference && encode_entity_reference(reference.entity_reference)
        }
      end

      def encode_entity_reference(reference)
        if reference.indirect?
          steps = reference.steps.map do |step|
            {
              '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$EntityRefStep',
              'Association' => step.association,
              'DestinationEntity' => step.destination_entity
            }
          end
          return {
            '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$IndirectEntityRef',
            'Steps' => IO::BsonCodec.build_array(steps, marker: 2)
          }
        end

        {
          '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$DirectEntityRef',
          'Entity' => reference.entity
        }
      end

      def encode_data_type(type)
        document = {
          '$ID' => SecureRandom.uuid,
          '$Type' => "DataTypes$#{type.name.to_s.sub(/Type\z/, '')}Type"
        }
        target_field = { 'Object' => 'Entity', 'List' => 'Entity', 'Enumeration' => 'Enumeration' }[type.name]
        document[target_field] = type.target if target_field && type.target
        document
      end

      def encode_condition(condition)
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Enumerations$Condition',
          'AttributeValue' => condition.attribute_value,
          'EditableVisible' => condition.editable_visible
        }
      end

      def encode_reference(reference, path:)
        return reference.target unless reference.kind == :by_id
        local = @local_encode_references&.fetch(reference.target.to_s, nil)
        return local if local
        unless reference_encoder
          raise UnresolvedStorageReferenceError, "by-id reference at #{path} requires a semantic resolver"
        end

        reference_encoder.call(reference.target, path)
      end

      def storage_reference_names(document)
        entries = []
        walk_storage = lambda do |value, path|
          case value
          when Hash
            identifier = IO::BsonCodec.extract_id(value['$ID'])
            name = value['Name'].to_s
            entries << [identifier, name.empty? ? path : name] if identifier
            value.each do |key, child|
              next if %w[$ID TypePointer].include?(key.to_s)

              walk_storage.call(child, "#{path}.#{key}")
            end
          when Array
            IO::BsonCodec.parse_array(value).fetch(:items).each_with_index do |child, index|
              walk_storage.call(child, "#{path}[#{index}]")
            end
          end
        end
        walk_storage.call(document, '$')
        entries.to_h
      end

      def prepare_node_ids(root)
        @node_ids = {}.compare_by_identity
        named = Hash.new { |hash, key| hash[key] = [] }
        walk_typed_nodes(root) do |node|
          identifier = SecureRandom.uuid
          @node_ids[node] = identifier
          name = node.fetch(:name).to_s if node.schema_type.property(:name)
          named[name] << identifier unless name.to_s.empty?
        end
        @local_encode_references = named.to_h do |name, identifiers|
          [name, identifiers.one? ? identifiers.first : nil]
        end.compact
      end

      def walk_typed_nodes(value, &block)
        case value
        when Node
          yield value
          value.assignments.each { walk_typed_nodes(_1.value, &block) }
        when Pluggable::Node
          value.assigned_outer.each_value { walk_typed_nodes(_1, &block) }
          walk_typed_nodes(value.object, &block)
        when Pluggable::ObjectNode
          value.assignments.each do |assignment|
            walk_typed_nodes(assignment.value, &block)
            walk_typed_nodes(assignment.source_variable, &block)
          end
        when Pluggable::XPathSource
          walk_typed_nodes(value.sort_bar, &block)
          walk_typed_nodes(value.source_variable, &block)
        when Array
          value.each { walk_typed_nodes(_1, &block) }
        end
      end

      def node_identifier(node)
        @node_ids&.fetch(node) { @node_ids[node] = SecureRandom.uuid } || SecureRandom.uuid
      end

      def encode_text(text)
        items = text.translations.map do |translation|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
            'LanguageCode' => translation.language.to_s, 'Text' => translation.text.to_s
          }
        end
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
          'Items' => IO::BsonCodec.build_array(items, marker: 3)
        }
      end

      def encode_text_template(template, path:) # rubocop:disable Metrics/MethodLength
        parameters = template.parameters.map.with_index do |parameter, index|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Microflows$TemplateParameter',
            'Expression' => parameter.expression.to_s,
            'ExpressionModel' => no_expression_document("#{path}.Parameters[#{index}]")
          }
        end
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Microflows$TextTemplate',
          'Text' => encode_text(template.text),
          'Parameters' => IO::BsonCodec.build_array(parameters, marker: 2)
        }
      end

      def collection_marker(property)
        return 1 if property.reference == :by_name

        COLLECTION_MARKERS.fetch([property.declared_by, property.name], 2)
      end

      def add_expression_companion(document, property, storage)
        return unless storage == 'Expression' && %w[ConditionalSettings WidgetValidation].include?(property.declared_by)

        document['ExpressionModel'] = no_expression_document("$.#{storage}")
      end

      def no_expression_document(_path)
        { '$ID' => SecureRandom.uuid, '$Type' => 'Expressions$NoExpression' }
      end
    end
  end
end
