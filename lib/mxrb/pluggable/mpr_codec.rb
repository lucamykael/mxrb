# frozen_string_literal: true

require 'securerandom'
require_relative 'node'
require_relative '../io/bson_codec'

module Mxrb
  module Pluggable
    class CodecError < StandardError; end
    class UnsupportedStoragePropertyError < CodecError; end

    # Strict CustomWidgets BSON boundary. UUID pointers are resolved locally
    # and discarded; callers receive only semantic, typed Ruby objects.
    class MprCodec # rubocop:disable Metrics/ClassLength
      OUTER_STORAGE = {
        identifier: 'Name', appearance: 'Appearance',
        conditional_editability: 'ConditionalEditabilitySettings',
        editable: 'Editable', label_template: 'LabelTemplate',
        conditional_visibility: 'ConditionalVisibilitySettings', tab_index: 'TabIndex'
      }.freeze
      WIDGET_VALUE_FIELDS = %w[
        $ID $Type Action AttributeRef DataSource EntityRef Expression Form Icon Image
        Microflow Nanoflow Objects PrimitiveValue Selection SourceVariable TextTemplate
        TranslatableValue TypePointer Widgets XPathConstraint
      ].freeze
      LEGACY_OUTER_PROPERTIES = {
        'AttributePath' => %w[attribute Attribute],
        'LabelText' => %w[label TranslatableString],
        'SelectorType' => %w[selector_type Enumeration],
        'DisplayAttribute' => %w[display_attribute Attribute]
      }.freeze

      def initialize(forms_codec:, catalog: Catalog.default)
        @forms_codec = forms_codec
        @catalog = catalog
      end

      def decode(document, path: '$')
        require_type!(document, 'CustomWidgets$CustomWidget', path)
        definition, context = decode_widget_type(document.fetch('Type'), path: "#{path}.Type")
        definition = with_legacy_outer_properties(definition, document)
        definition = catalog.register(definition)
        node = Node.new(definition, catalog:)
        OUTER_STORAGE.each do |semantic, storage|
          next unless document.key?(storage)

          node.public_send(semantic, decode_outer(semantic, document[storage], path: "#{path}.#{storage}"))
        end
        decode_object(document.fetch('Object'), definition.object_type, context,
                      path: "#{path}.Object", target: node.object)
        decode_legacy_outer_properties(node.object, document)
        known = %w[$ID $Type Type Object] + OUTER_STORAGE.values + LEGACY_OUTER_PROPERTIES.keys
        assert_known!(document, known, path)
        node
      end

      def encode(node, path: '$')
        raise TypeError, 'expected Pluggable::Node' unless node.is_a?(Node)

        baseline = forms_codec.pluggable_baseline_for(node)
        widget_type = if baseline
                        decode_widget_type(baseline.fetch('Type'), path: "#{path}.Type").first
                      else
                        catalog.resolve(node.widget_type.id, node.object)
                      end
        type_document, context = encode_widget_type(widget_type)
        document = {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidget',
          'Type' => type_document,
          'Object' => encode_object(node.object, widget_type.object_type, context,
                                    path: "#{path}.Object")
        }
        node.assigned_outer.each do |semantic, value|
          storage = OUTER_STORAGE.fetch(semantic)
          document[storage] = encode_outer(semantic, value, path: "#{path}.#{storage}")
        end
        restore_schema_identity!(document, baseline) if baseline
        document
      end

      def register_type(document, path: '$.Type')
        definition, = decode_widget_type(document, path:)
        catalog.register(definition)
      end

      private

      attr_reader :forms_codec, :catalog

      def with_legacy_outer_properties(definition, document)
        additions = LEGACY_OUTER_PROPERTIES.filter_map do |storage, (key, kind)|
          next unless document.key?(storage)
          next if definition.object_type.property(key)

          legacy_property_type(key, kind)
        end
        return definition if additions.empty?

        WidgetType.new(
          definition.id, definition.name, definition.description, definition.prompt,
          definition.studio_pro_category, definition.studio_category, definition.platform,
          definition.offline, definition.needs_context, definition.plugin, definition.help_url,
          ObjectType.new((definition.object_type.properties + additions).freeze)
        )
      end

      def legacy_property_type(key, kind)
        value_type = ValueType.new(
          kind:, list: false, linked: false, metadata: false, entity_property: '',
          allow_non_persistable_entities: false, path_kind: 'No', path_type: 'None',
          parameter_list: false, multiline: false, default_value: '', required: false,
          on_change_property: '', data_source_property: '', selectable_objects_property: '',
          attribute_types: [].freeze, association_types: [].freeze, selection_types: [].freeze,
          enumeration_values: [].freeze, action_variables: [].freeze, object_type: nil,
          return_type: nil, translations: [].freeze, set_label: false,
          default_type: 'None', allow_upload: false
        )
        PropertyType.new(
          key:, ruby_name: Forms::Naming.ruby_name(key), category: 'Legacy migration',
          caption: key, description: '', prompt: '', default: false, value_type:
        )
      end

      def decode_legacy_outer_properties(object, document)
        LEGACY_OUTER_PROPERTIES.each do |storage, (key, kind)|
          next unless document.key?(storage)

          value = case kind
                  when 'Attribute' then Forms::AttributeReference.coerce(document[storage].to_s)
                  when 'TranslatableString' then decode_text(document[storage])
                  else document[storage].to_s
                  end
          object.set(key, value)
        end
      end

      def decode_widget_type(document, path:)
        require_type!(document, 'CustomWidgets$CustomWidgetType', path)
        context = { property_types: {}, object_types: {} }
        object_type = decode_object_type(document.fetch('ObjectType'), context, path: "#{path}.ObjectType")
        definition = WidgetType.new(
          document.fetch('WidgetId').to_s.freeze,
          document.fetch('WidgetName', document.fetch('Name', '')).to_s.freeze,
          document.fetch('WidgetDescription', document.fetch('Description', '')).to_s.freeze,
          document.fetch('Prompt', '').to_s.freeze,
          document.fetch('StudioProCategory', '').to_s.freeze,
          document.fetch('StudioCategory', '').to_s.freeze,
          document.fetch('SupportedPlatform', 'Web').to_s.freeze,
          boolean(document.fetch('OfflineCapable', false)),
          boolean(document.fetch('WidgetNeedsEntityContext', document.fetch('NeedsEntityContext', false))),
          boolean(document.fetch('WidgetPluginWidget', document.fetch('PluginWidget', false))),
          document.fetch('HelpUrl', '').to_s.freeze,
          object_type
        )
        known = %w[
          $ID $Type WidgetId WidgetName Name WidgetDescription Description Prompt
          StudioProCategory StudioCategory SupportedPlatform OfflineCapable
          WidgetNeedsEntityContext NeedsEntityContext WidgetPluginWidget PluginWidget
          HelpUrl ObjectType
        ]
        assert_known!(document, known, path)
        [definition, context]
      end

      def decode_object_type(document, context, path:)
        require_type!(document, 'CustomWidgets$WidgetObjectType', path)
        object_type_id = storage_id(document['$ID'])
        properties = array_items(document['PropertyTypes']).map.with_index do |property, index|
          decode_property_type(property, context, path: "#{path}.PropertyTypes[#{index}]")
        end.freeze
        object_type = ObjectType.new(properties)
        context[:object_types][object_type_id] = object_type if object_type_id
        assert_known!(document, %w[$ID $Type PropertyTypes], path)
        object_type
      end

      def decode_property_type(document, context, path:)
        require_type!(document, 'CustomWidgets$WidgetPropertyType', path)
        key = document['PropertyKey'] || document['_Key'] || document['Key'] || ''
        value_type = decode_value_type(document.fetch('ValueType'), context, path: "#{path}.ValueType")
        property = PropertyType.new(
          key.to_s.freeze, Forms::Naming.ruby_name(key).freeze,
          document.fetch('Category', '').to_s.freeze,
          document.fetch('Caption', '').to_s.freeze,
          document.fetch('Description', '').to_s.freeze,
          document.fetch('Prompt', '').to_s.freeze,
          boolean(document.fetch('IsDefault', false)), value_type
        )
        identifier = storage_id(document['$ID'])
        context[:property_types][identifier] = property if identifier
        assert_known!(document,
                      %w[$ID $Type PropertyKey _Key Key Category Caption Description Prompt IsDefault ValueType], path)
        property
      end

      def decode_value_type(document, context, path:)
        require_type!(document, 'CustomWidgets$WidgetValueType', path)
        object_type = document['ObjectType'] &&
                      decode_object_type(document['ObjectType'], context, path: "#{path}.ObjectType")
        value_type = ValueType.new(
          document.fetch('Type', 'String').to_s.freeze,
          boolean(document.fetch('IsList', false)), boolean(document.fetch('IsLinked', false)),
          boolean(document.fetch('IsMetaData', false)), document.fetch('EntityProperty', '').to_s.freeze,
          boolean(document.fetch('AllowNonPersistableEntities', false)),
          document.fetch('IsPath', 'No').to_s.freeze, document.fetch('PathType', 'None').to_s.freeze,
          boolean(document.fetch('ParameterIsList', false)), boolean(document.fetch('Multiline', false)),
          document.fetch('DefaultValue', '').to_s.freeze, boolean(document.fetch('Required', false)),
          document.fetch('OnChangeProperty', '').to_s.freeze,
          document.fetch('DataSourceProperty', '').to_s.freeze,
          document.fetch('SelectableObjectsProperty', '').to_s.freeze,
          string_array(document['AttributeTypes'] || document['AllowedTypes']),
          string_array(document['AssociationTypes']), string_array(document['SelectionTypes']),
          decode_enumerations(document['EnumerationValues'], path:),
          decode_action_variables(document['ActionVariables'], path:), object_type,
          decode_return_type(document['ReturnType'], path:),
          decode_translations(document['Translations'], path:), boolean(document.fetch('SetLabel', false)),
          document.fetch('DefaultType', 'None').to_s.freeze, boolean(document.fetch('AllowUpload', false))
        )
        context[:value_types] ||= {}
        identifier = storage_id(document['$ID'])
        context[:value_types][identifier] = value_type if identifier
        known = %w[
          $ID $Type Type IsList IsLinked IsMetaData EntityProperty
          AllowNonPersistableEntities IsPath PathType ParameterIsList Multiline
          DefaultValue Required OnChangeProperty DataSourceProperty
          SelectableObjectsProperty AttributeTypes AllowedTypes AssociationTypes
          SelectionTypes EnumerationValues ActionVariables ObjectType ReturnType
          Translations SetLabel DefaultType AllowUpload
        ]
        assert_known!(document, known, path)
        value_type
      end

      def decode_object(document, schema, context, path:, target: ObjectNode.new(schema))
        require_type!(document, 'CustomWidgets$WidgetObject', path)
        array_items(document['Properties']).each_with_index do |stored, index|
          property = context[:property_types][storage_id(stored['TypePointer'])]
          raise CodecError, "unresolved widget property pointer at #{path}.Properties[#{index}]" unless property

          value = decode_value(stored.fetch('Value'), property.value_type, context,
                               path: "#{path}.#{property.key}")
          source = if property.value_type.kind != 'DataSource'
                     decode_optional_forms(stored.fetch('Value')['SourceVariable'])
                   end
          target.set(property.key, value, source:)
          assert_known!(stored, %w[$ID $Type TypePointer Value], "#{path}.Properties[#{index}]")
        end
        assert_known!(document, %w[$ID $Type TypePointer Properties], path)
        target
      end

      def decode_value(document, value_type, context, path:)
        require_type!(document, 'CustomWidgets$WidgetValue', path)
        assert_known!(document, WIDGET_VALUE_FIELDS, path)
        case value_type.kind
        when 'Boolean' then document.fetch('PrimitiveValue', 'false').to_s == 'true'
        when 'Integer' then Integer(document.fetch('PrimitiveValue', '0'))
        when 'Decimal' then Decimal.coerce(document.fetch('PrimitiveValue', '0'))
        when 'String', 'Enumeration' then document.fetch('PrimitiveValue', '').to_s
        when 'Selection' then document.fetch('Selection', 'None').to_s
        when 'Expression' then Forms::Expression.coerce(document.fetch('Expression', ''))
        when 'EntityConstraint' then Forms::XPathConstraint.coerce(document.fetch('XPathConstraint', ''))
        when 'Attribute'
          document['AttributeRef'] && forms_codec.decode_attribute_reference_value(
            document['AttributeRef'], path: "#{path}.AttributeRef"
          )
        when 'Entity'
          document['EntityRef'] && forms_codec.decode_entity_reference_value(
            document['EntityRef'], path: "#{path}.EntityRef"
          )
        when 'TranslatableString' then decode_text(document['TranslatableValue'])
        when 'TextTemplate' then decode_optional_forms(document['TextTemplate'])
        when 'Action' then decode_optional_forms(document['Action'])
        when 'Icon' then decode_optional_forms(document['Icon'])
        when 'DataSource' then decode_data_source(document, path:)
        when 'Object' then decode_objects(document['Objects'], value_type, context, path:)
        when 'Widgets' then decode_widgets(document['Widgets'], path:)
        when 'System' then nil
        else decode_semantic_reference(value_type.kind, document)
        end
      end

      def decode_objects(raw, value_type, context, path:)
        items = array_items(raw).map.with_index do |item, index|
          decode_object(item, value_type.object_type, context, path: "#{path}[#{index}]")
        end
        value_type.list? ? items.freeze : items.first
      end

      def decode_widgets(raw, path:)
        array_items(raw).map.with_index do |item, index|
          item_path = "#{path}[#{index}]"
          if item['$Type'] == 'CustomWidgets$CustomWidget'
            decode(item, path: item_path)
          else
            forms_codec.decode_embedded(item, path: item_path)
          end
        end.freeze
      end

      def decode_data_source(document, path:)
        source = document['DataSource']
        variable = decode_optional_forms(document['SourceVariable'] || source&.fetch('SourceVariable', nil))
        return nil unless source || variable
        return XPathSource.new(nil, nil, nil, variable, false) unless source

        type = source.fetch('$Type', '')
        unless %w[CustomWidgets$CustomWidgetXPathSource CustomWidgets$CustomWidgetDatabaseSource].include?(type)
          return forms_codec.decode_embedded(source, path: "#{path}.DataSource")
        end

        known = %w[
          $ID $Type EntityRef XPathConstraint DatabaseConstraints SortBar SourceVariable ForceFullObjects
        ]
        assert_known!(source, known, "#{path}.DataSource")
        XPathSource.new(
          source['EntityRef'] && forms_codec.decode_entity_reference_value(
            source['EntityRef'], path: "#{path}.DataSource.EntityRef"
          ),
          Forms::XPathConstraint.coerce(source['XPathConstraint'] || source['DatabaseConstraints'] || ''),
          decode_optional_forms(source['SortBar']), variable, !!source.fetch('ForceFullObjects', false)
        )
      end

      def decode_semantic_reference(kind, document)
        if kind == 'Association' && document['EntityRef']
          target = forms_codec.decode_entity_reference_value(document['EntityRef'], path: '$.EntityRef')
          return Pluggable.reference(kind, target)
        end

        field = {
          'Association' => 'AttributeRef', 'File' => 'Image', 'Form' => 'Form',
          'Image' => 'Image', 'Microflow' => 'Microflow', 'Nanoflow' => 'Nanoflow'
        }.fetch(kind) { kind }
        value = document[field]
        return nil if value.nil? || value == ''

        target = if kind == 'Association'
                   forms_codec.decode_attribute_reference_value(value, path: '$.AttributeRef')
                 else
                   reference_path(value, field)
                 end
        Pluggable.reference(kind, target)
      end

      def encode_widget_type(widget_type)
        context = {
          property_ids: {}.compare_by_identity,
          value_type_ids: {}.compare_by_identity,
          object_type_ids: {}.compare_by_identity
        }
        object_type = encode_object_type(widget_type.object_type, context)
        document = {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidgetType',
          'HelpUrl' => widget_type.help_url, 'OfflineCapable' => widget_type.offline,
          'StudioCategory' => widget_type.studio_category,
          'StudioProCategory' => widget_type.studio_pro_category,
          'SupportedPlatform' => widget_type.platform,
          'WidgetDescription' => widget_type.description, 'WidgetId' => widget_type.id,
          'WidgetName' => widget_type.name, 'Prompt' => widget_type.prompt,
          'WidgetNeedsEntityContext' => widget_type.needs_context,
          'WidgetPluginWidget' => widget_type.plugin, 'ObjectType' => object_type
        }
        [document, context]
      end

      def encode_object_type(object_type, context)
        identifier = SecureRandom.uuid
        context[:object_type_ids][object_type] = identifier
        properties = object_type.properties.map { encode_property_type(_1, context) }
        {
          '$ID' => identifier, '$Type' => 'CustomWidgets$WidgetObjectType',
          'PropertyTypes' => IO::BsonCodec.build_array(properties, marker: 2)
        }
      end

      def encode_property_type(property, context)
        identifier = SecureRandom.uuid
        context[:property_ids][property] = identifier
        {
          '$ID' => identifier, '$Type' => 'CustomWidgets$WidgetPropertyType',
          'Caption' => property.caption, 'Category' => property.category,
          'Description' => property.description, 'IsDefault' => property.default,
          'PropertyKey' => property.key, 'Prompt' => property.prompt,
          'ValueType' => encode_value_type(property.value_type, context)
        }
      end

      SCHEMA_STORAGE_ALIASES = {
        'CustomWidgets$CustomWidgetType' => {
          'Name' => 'WidgetName', 'Description' => 'WidgetDescription',
          'NeedsEntityContext' => 'WidgetNeedsEntityContext', 'PluginWidget' => 'WidgetPluginWidget'
        },
        'CustomWidgets$WidgetPropertyType' => { '_Key' => 'PropertyKey', 'Key' => 'PropertyKey' },
        'CustomWidgets$WidgetValueType' => { 'AttributeTypes' => 'AllowedTypes' },
        'CustomWidgets$WidgetEnumerationValue' => { 'Key' => '_Key' },
        'CustomWidgets$WidgetActionVariable' => { '_Key' => 'Key' }
      }.transform_values(&:freeze).freeze
      private_constant :SCHEMA_STORAGE_ALIASES

      def restore_schema_identity!(document, baseline)
        replacements = {}
        restore_schema_fields!(document.fetch('Type'), baseline.fetch('Type'), replacements)
        rewrite_type_pointers!(document.fetch('Object'), replacements)
      end

      def restore_schema_fields!(generated, baseline, replacements)
        case generated
        when Hash
          restore_schema_hash!(generated, baseline, replacements) if baseline.is_a?(Hash)
        when Array
          return unless baseline.is_a?(Array)

          restore_schema_array!(generated, baseline, replacements)
        end
      end

      def restore_schema_array!(generated, baseline, replacements)
        values = array_items(generated)
        previous_values = array_items(baseline)
        return unless values.all?(Hash) || previous_values.all?(Hash)

        unless values.length == previous_values.length && values.all?(Hash) && previous_values.all?(Hash)
          raise CodecError, 'embedded widget schema collection changed shape'
        end

        candidates = previous_values.group_by { schema_identity(_1) }
        values.each do |value|
          identity = schema_identity(value)
          matches = candidates.fetch(identity, [])
          raise CodecError, "ambiguous embedded widget schema identity #{identity.inspect}" unless matches.one?

          restore_schema_fields!(value, matches.first, replacements)
          candidates.delete(identity)
        end
      end

      def schema_identity(document)
        type = document.fetch('$Type', '')
        %w[PropertyKey _Key Key LanguageCode WidgetId].each do |field|
          logical_field = %w[PropertyKey _Key Key].include?(field) ? 'Key' : field
          return [type, logical_field, document[field].to_s] if document.key?(field)
        end
        [type]
      end

      def restore_schema_hash!(generated, baseline, replacements)
        # The baseline selected the concrete schema above. Field presence and
        # BSON key order are part of its identity: adding an empty Prompt or
        # reordering fields makes Studio report an outdated widget.
        aliases = SCHEMA_STORAGE_ALIASES.fetch(generated['$Type'], {})
        fields = baseline.each_key.with_object({}) do |key, restored|
          canonical = aliases.fetch(key, key)
          restored[key] = generated.fetch(canonical) if generated.key?(canonical)
        end
        generated.replace(fields)
        old_id = storage_id(generated['$ID'])
        if old_id && baseline.key?('$ID')
          generated['$ID'] = baseline['$ID']
          replacements[old_id] = baseline['$ID']
        end
        generated.each { |key, value| restore_schema_fields!(value, baseline[key], replacements) }
      end

      def rewrite_type_pointers!(value, replacements)
        case value
        when Hash
          if value.key?('TypePointer')
            replacement = replacements[storage_id(value['TypePointer'])]
            value['TypePointer'] = replacement if replacement
          end
          value.each_value { rewrite_type_pointers!(_1, replacements) }
        when Array
          value.each { rewrite_type_pointers!(_1, replacements) unless _1.is_a?(Integer) }
        end
      end

      def encode_value_type(value_type, context)
        identifier = SecureRandom.uuid
        context[:value_type_ids][value_type] = identifier
        {
          '$ID' => identifier, '$Type' => 'CustomWidgets$WidgetValueType',
          'ActionVariables' => encode_action_variables(value_type.action_variables),
          'AllowedTypes' => marked(value_type.attribute_types, 1),
          'AllowNonPersistableEntities' => value_type.allow_non_persistable_entities,
          'AllowUpload' => value_type.allow_upload,
          'AssociationTypes' => marked(value_type.association_types, 1),
          'DataSourceProperty' => value_type.data_source_property,
          'DefaultType' => value_type.default_type, 'DefaultValue' => value_type.default_value,
          'EntityProperty' => value_type.entity_property,
          'EnumerationValues' => encode_enumerations(value_type.enumeration_values),
          'IsLinked' => value_type.linked, 'IsList' => value_type.list,
          'IsMetaData' => value_type.metadata, 'IsPath' => value_type.path_kind,
          'Multiline' => value_type.multiline,
          'ObjectType' => value_type.object_type && encode_object_type(value_type.object_type, context),
          'OnChangeProperty' => value_type.on_change_property,
          'ParameterIsList' => value_type.parameter_list, 'PathType' => value_type.path_type,
          'Required' => value_type.required,
          'ReturnType' => encode_return_type(value_type.return_type),
          'SelectableObjectsProperty' => value_type.selectable_objects_property,
          'SelectionTypes' => marked(value_type.selection_types, 1),
          'SetLabel' => value_type.set_label,
          'Translations' => encode_translations(value_type.translations), 'Type' => value_type.kind
        }
      end

      def encode_object(object, schema, context, path:)
        properties = object.assignments.map do |assignment|
          property = schema.fetch_property(assignment.property.key)
          value_type_id = context[:value_type_ids].fetch(property.value_type)
          stored = {
            '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetProperty',
            'TypePointer' => context[:property_ids].fetch(property),
            'Value' => encode_value(assignment.value, property.value_type,
                                    value_type_id, context, path: "#{path}.#{assignment.property.key}")
          }
          if assignment.source_variable
            stored['Value']['SourceVariable'] = encode_optional_forms(assignment.source_variable)
          end
          stored
        end
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObject',
          'TypePointer' => context[:object_type_ids].fetch(schema),
          'Properties' => marked(properties, 2)
        }
      end

      def encode_value(value, value_type, type_id, context, path:)
        document = empty_widget_value(type_id)
        case value_type.kind
        when 'Boolean' then document['PrimitiveValue'] = value.to_s
        when 'Integer', 'Decimal', 'String', 'Enumeration'
          document['PrimitiveValue'] = value.to_s
        when 'Selection' then document['Selection'] = value.to_s
        when 'Expression' then document['Expression'] = value.to_s
        when 'EntityConstraint' then document['XPathConstraint'] = value.to_s
        when 'Attribute'
          document['AttributeRef'] = forms_codec.encode_attribute_reference_value(value) if value
        when 'Entity'
          document['EntityRef'] = forms_codec.encode_entity_reference_value(value) if value
        when 'TranslatableString' then document['TranslatableValue'] = encode_text(value)
        when 'TextTemplate' then document['TextTemplate'] = encode_optional_forms(value)
        when 'Action' then document['Action'] = encode_optional_forms(value)
        when 'Icon' then document['Icon'] = encode_optional_forms(value)
        when 'DataSource' then encode_data_source(document, value, path:)
        when 'Object' then document['Objects'] = encode_objects(value, value_type, context, path:)
        when 'Widgets' then document['Widgets'] = encode_widgets(value, path:)
        when 'System' then nil
        else encode_semantic_reference(document, value_type.kind, value)
        end
        document
      end

      def empty_widget_value(type_id)
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetValue',
          'Action' => { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$NoAction',
                        'DisabledDuringExecution' => true },
          'AttributeRef' => nil, 'DataSource' => nil, 'EntityRef' => nil,
          'Expression' => '', 'Form' => '', 'Icon' => nil, 'Image' => '',
          'Microflow' => '', 'Nanoflow' => '', 'Objects' => marked([], 2),
          'PrimitiveValue' => '', 'Selection' => 'None', 'SourceVariable' => nil,
          'TextTemplate' => nil, 'TranslatableValue' => nil, 'TypePointer' => type_id,
          'Widgets' => marked([], 2), 'XPathConstraint' => ''
        }
      end

      def encode_objects(value, value_type, context, path:)
        values = value_type.list? ? value : [value].compact
        marked(values.map.with_index do |object, index|
          encode_object(object, value_type.object_type, context, path: "#{path}[#{index}]")
        end, 2)
      end

      def encode_widgets(values, path:)
        marked(values.map.with_index do |widget, index|
          if widget.is_a?(Node)
            encode(widget, path: "#{path}[#{index}]")
          else
            forms_codec.encode_embedded(widget, path: "#{path}[#{index}]")
          end
        end, 2)
      end

      def encode_data_source(document, source, path:)
        return unless source

        if source.is_a?(Forms::Node)
          document['DataSource'] = forms_codec.encode_embedded(source, path: "#{path}.DataSource")
          return
        end
        unless source.entity || source.constraint || source.sort_bar || source.force_full_objects
          document['SourceVariable'] = forms_codec.encode_embedded(source.source_variable) if source.source_variable
          return
        end

        document['DataSource'] = {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
          'EntityRef' => source.entity && forms_codec.encode_entity_reference_value(source.entity),
          'XPathConstraint' => source.constraint.to_s,
          'SortBar' => encode_optional_forms(source.sort_bar),
          'SourceVariable' => encode_optional_forms(source.source_variable),
          'ForceFullObjects' => !!source.force_full_objects
        }
      rescue StandardError => e
        raise CodecError, "cannot encode data source at #{path}: #{e.message}"
      end

      def encode_semantic_reference(document, kind, reference)
        return if reference.nil?

        if kind == 'Association' && reference.target.is_a?(Forms::EntityReference)
          document['EntityRef'] = forms_codec.encode_entity_reference_value(reference.target)
          return
        end

        field = {
          'Association' => 'AttributeRef', 'File' => 'Image', 'Form' => 'Form',
          'Image' => 'Image', 'Microflow' => 'Microflow', 'Nanoflow' => 'Nanoflow'
        }.fetch(kind) { kind }
        document[field] = if kind == 'Association'
                            forms_codec.encode_attribute_reference_value(reference.target)
                          else
                            reference.target
                          end
      end

      def decode_outer(field, value, path:)
        return nil if value.nil?

        case field
        when :appearance, :conditional_editability, :label_template, :conditional_visibility
          forms_codec.decode_embedded(value, path:)
        when :editable then Forms::Naming.ruby_name(value).to_sym
        else value
        end
      rescue StandardError => e
        raise CodecError, "cannot decode #{field} at #{path}: #{e.message}"
      end

      def encode_outer(field, value, path:)
        return nil if value.nil?
        return forms_codec.encode_embedded(value, path:) if value.is_a?(Forms::Node)
        return camelize(value) if field == :editable

        value
      rescue StandardError => e
        raise CodecError, "cannot encode #{field} at #{path}: #{e.message}"
      end

      def decode_optional_forms(value) = value && forms_codec.decode_embedded(value)
      def encode_optional_forms(value) = value && forms_codec.encode_embedded(value)

      def decode_text(value)
        return Forms::Text.coerce([]) unless value

        translations = array_items(value['Items']).map do |item|
          Forms::Translation.new(item['LanguageCode'].to_s, item.fetch('Text', '').to_s)
        end
        Forms::Text.coerce(translations)
      end

      def encode_text(value)
        items = value.translations.map do |translation|
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
            'LanguageCode' => translation.language.to_s, 'Text' => translation.text
          }
        end
        { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text', 'Items' => marked(items, 3) }
      end

      def decode_enumerations(raw, path:)
        array_items(raw).map.with_index do |item, index|
          assert_known!(item, %w[$ID $Type _Key Key Caption], "#{path}.EnumerationValues[#{index}]")
          EnumerationValue.new((item['_Key'] || item['Key'] || '').to_s.freeze,
                               item.fetch('Caption', '').to_s.freeze)
        end.freeze
      end

      def decode_action_variables(raw, path:)
        array_items(raw).map.with_index do |item, index|
          assert_known!(item, %w[$ID $Type Key _Key Type Caption], "#{path}.ActionVariables[#{index}]")
          ActionVariable.new((item['Key'] || item['_Key'] || '').to_s.freeze,
                             item.fetch('Type', 'None').to_s.freeze,
                             item.fetch('Caption', '').to_s.freeze)
        end.freeze
      end

      def decode_return_type(item, path:)
        return unless item

        assert_known!(item, %w[$ID $Type Type IsList EntityProperty AssignableTo], "#{path}.ReturnType")
        ReturnType.new(item.fetch('Type', 'None').to_s.freeze, boolean(item.fetch('IsList', false)),
                       item.fetch('EntityProperty', '').to_s.freeze,
                       item.fetch('AssignableTo', '').to_s.freeze)
      end

      def decode_translations(raw, path:)
        array_items(raw).map.with_index do |item, index|
          assert_known!(item, %w[$ID $Type LanguageCode Text], "#{path}.Translations[#{index}]")
          Translation.new(item.fetch('LanguageCode', '').to_s.freeze,
                          item.fetch('Text', '').to_s.freeze)
        end.freeze
      end

      def encode_enumerations(values)
        marked(values.map do |value|
          { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetEnumerationValue',
            '_Key' => value.key, 'Caption' => value.caption }
        end, 2)
      end

      def encode_action_variables(values)
        marked(values.map do |value|
          { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetActionVariable',
            'Caption' => value.caption, 'Key' => value.key, 'Type' => value.kind }
        end, 2)
      end

      def encode_return_type(value)
        return unless value

        { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetReturnType',
          'AssignableTo' => value.assignable_to, 'EntityProperty' => value.entity_property,
          'IsList' => value.list, 'Type' => value.kind }
      end

      def encode_translations(values)
        marked(values.map do |value|
          { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetTranslation',
            'LanguageCode' => value.language, 'Text' => value.text }
        end, 2)
      end

      def reference_path(value, key)
        return value.to_s unless value.is_a?(Hash)

        value[key] || value["#{key}Path"] || ''
      end

      def string_array(value) = array_items(value).map { _1.to_s.freeze }.freeze
      def array_items(value) = IO::BsonCodec.parse_array(value).fetch(:items)
      def marked(value, marker) = IO::BsonCodec.build_array(value, marker:)
      def storage_id(value) = IO::BsonCodec.extract_id(value)
      def boolean(value) = value ? true : false

      def require_type!(document, expected, path)
        raise CodecError, "expected #{expected} at #{path}" unless document.is_a?(Hash) && document['$Type'] == expected
      end

      def assert_known!(document, known, path)
        unknown = document.keys.map(&:to_s) - known
        return if unknown.empty?

        raise UnsupportedStoragePropertyError, "unmapped storage field(s) at #{path}: #{unknown.sort.join(', ')}"
      end

      def camelize(value) = value.to_s.split('_').map(&:capitalize).join
    end
  end
end
