# frozen_string_literal: true

require 'rexml/document'
require 'zip'

module Mxrb
  # Reads pluggable-widget metadata directly from installed MPK files and builds
  # the embedded Mendix WidgetType/WidgetObject pair without Studio Pro.
  class WidgetPackage # rubocop:disable Metrics/ClassLength
    TYPE_MAP = {
      'attribute' => 'Attribute', 'expression' => 'Expression',
      'texttemplate' => 'TextTemplate', 'widgets' => 'Widgets',
      'enumeration' => 'Enumeration', 'boolean' => 'Boolean',
      'integer' => 'Integer', 'datasource' => 'DataSource', 'action' => 'Action',
      'selection' => 'Selection', 'association' => 'Association', 'object' => 'Object',
      'string' => 'String', 'decimal' => 'Decimal', 'icon' => 'Icon',
      'image' => 'Image', 'file' => 'File'
    }.freeze

    Definition = Data.define(
      :id, :name, :description, :help_url, :studio_category, :studio_pro_category,
      :platform, :offline, :needs_context, :plugin, :properties
    )

    def self.find(root, widget_id)
      Dir.glob(File.join(File.expand_path(root), 'widgets', '*.mpk')).sort.each do |path|
        definition = new(path).definition(widget_id)
        return definition if definition
      rescue Zip::Error, REXML::ParseException
        next
      end
      nil
    end

    def self.template(definition) = allocate.template(definition)

    def initialize(path)
      @path = path
    end

    def definition(widget_id)
      Zip::File.open(@path) do |archive|
        widget_entries(archive).each do |entry|
          root = REXML::Document.new(entry.get_input_stream.read).root
          next unless root&.attributes&.[]('id') == widget_id

          return build_definition(root)
        end
      end
      nil
    end

    def template(definition) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      object_type_id = SecureRandom.uuid
      property_types = []
      properties = []
      definition.properties.each do |property|
        property_type, value = property_pair(property)
        property_types << property_type
        properties << value if value
      end
      type = {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidgetType',
        'HelpUrl' => definition.help_url, 'OfflineCapable' => definition.offline,
        'StudioCategory' => definition.studio_category,
        'StudioProCategory' => definition.studio_pro_category,
        'SupportedPlatform' => definition.platform,
        'WidgetDescription' => definition.description,
        'WidgetId' => definition.id, 'WidgetName' => definition.name,
        'WidgetNeedsEntityContext' => definition.needs_context,
        'WidgetPluginWidget' => definition.plugin,
        'ObjectType' => {
          '$ID' => object_type_id, '$Type' => 'CustomWidgets$WidgetObjectType',
          'PropertyTypes' => IO::BsonCodec.build_array(property_types, marker: 2)
        }
      }
      object = {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObject',
        'TypePointer' => object_type_id,
        'Properties' => IO::BsonCodec.build_array(properties, marker: 2)
      }
      [type, object]
    end

    private

    def widget_entries(archive)
      package = archive.find_entry('package.xml')
      return archive.select { _1.file? && _1.name.downcase.end_with?('.xml') } unless package

      document = REXML::Document.new(package.get_input_stream.read)
      paths = elements(document.root, 'widgetFile').filter_map { _1.attributes['path'] }
      paths.filter_map { archive.find_entry(_1) }
    end

    def build_definition(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      properties_root = child(root, 'properties')
      properties = properties_root ? property_groups(properties_root, nil) : []
      Definition.new(
        id: root.attributes['id'], name: text(root, 'name'),
        description: text(root, 'description'), help_url: text(root, 'helpUrl'),
        studio_category: text(root, 'studioCategory'),
        studio_pro_category: text(root, 'studioProCategory'),
        platform: root.attributes['supportedPlatform'].to_s.empty? ? 'Web' : root.attributes['supportedPlatform'],
        offline: root.attributes['offlineCapable'] == 'true',
        needs_context: root.attributes['needsEntityContext'] == 'true',
        plugin: root.attributes['pluginWidget'] == 'true', properties:
      )
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def property_groups(parent, category)
      parent.elements.to_a.flat_map do |element|
        next [] unless element.name == 'propertyGroup'

        group = [category, element.attributes['caption']].compact.reject(&:empty?).join('::')
        element.elements.to_a.flat_map do |member|
          case member.name
          when 'property' then [property(member, group)]
          when 'systemProperty' then [system_property(member, group)]
          when 'propertyGroup' then property_groups_wrapper(member, group)
          else []
          end
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    def property_groups_wrapper(group, parent_category)
      category = [parent_category, group.attributes['caption']].compact.reject(&:empty?).join('::')
      group.elements.to_a.flat_map do |member|
        case member.name
        when 'property' then [property(member, category)]
        when 'systemProperty' then [system_property(member, category)]
        when 'propertyGroup' then property_groups_wrapper(member, category)
        else []
        end
      end
    end

    def property(element, category) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      {
        key: element.attributes['key'], type: TYPE_MAP[element.attributes['type'].to_s.downcase],
        caption: text(element, 'caption'), description: text(element, 'description'), category:,
        required: element.attributes['required'] != 'false',
        default: element.attributes['defaultValue'].to_s,
        list: element.attributes['isList'] == 'true', multiline: element.attributes['multiline'] == 'true',
        data_source: element.attributes['dataSource'].to_s,
        on_change: element.attributes['onChange'].to_s,
        allowed_types: nested_element_names(element, 'attributeTypes', 'attributeType'),
        association_types: nested_element_names(element, 'associationTypes', 'associationType'),
        selection_types: nested_element_names(element, 'selectionTypes', 'selectionType'),
        enum_values: nested_elements(element, 'enumerationValues', 'enumerationValue').map do |value|
          [value.attributes['key'].to_s, value.text.to_s.strip]
        end,
        translations: nested_elements(element, 'translations', 'translation').map do |translation|
          [translation.attributes['lang'].to_s, translation.text.to_s.strip]
        end,
        return_type: return_type(element), children: nested_properties(element)
      }
    end

    def system_property(element, category)
      { key: element.attributes['key'], type: 'System', caption: "<system:#{element.attributes['key']}>",
        description: '', category:, required: false, default: '', list: false, multiline: false,
        data_source: '', on_change: '', allowed_types: [], association_types: [], selection_types: [],
        enum_values: [], translations: [], return_type: nil, children: [], system: true }
    end

    def nested_properties(element)
      root = child(element, 'properties')
      root ? property_groups(root, nil).reject { _1[:system] } : []
    end

    def return_type(element)
      node = child(element, 'returnType')
      return unless node

      { type: node.attributes['type'].to_s.empty? ? 'None' : node.attributes['type'],
        assignable_to: node.attributes['assignableTo'].to_s }
    end

    def property_pair(property) # rubocop:disable Metrics/MethodLength
      property_type_id = SecureRandom.uuid
      value_type = value_type(property)
      property_type = {
        '$ID' => property_type_id, '$Type' => 'CustomWidgets$WidgetPropertyType',
        'Caption' => property[:caption], 'Category' => property[:category],
        'Description' => property[:description], 'IsDefault' => false,
        'PropertyKey' => property[:key], 'ValueType' => value_type
      }
      return [property_type, nil] if property[:system]

      value = widget_value(value_type, property)
      widget_property = {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetProperty',
        'TypePointer' => property_type_id, 'Value' => value
      }
      [property_type, widget_property]
    end

    def value_type(property) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      type = property[:type]
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetValueType',
        'ActionVariables' => IO::BsonCodec.build_array([], marker: 2),
        'AllowedTypes' => IO::BsonCodec.build_array(property[:allowed_types], marker: 1),
        'AllowNonPersistableEntities' => false, 'AllowUpload' => false,
        'AssociationTypes' => IO::BsonCodec.build_array(property[:association_types], marker: 1),
        'DataSourceProperty' => property[:data_source], 'DefaultType' => 'None',
        'DefaultValue' => property[:default], 'EntityProperty' => '',
        'EnumerationValues' => enumeration_values(property[:enum_values]),
        'IsLinked' => false, 'IsList' => property[:list], 'IsMetaData' => false,
        'IsPath' => 'No', 'Multiline' => property[:multiline],
        'ObjectType' => object_type(property[:children]), 'OnChangeProperty' => property[:on_change],
        'ParameterIsList' => false, 'PathType' => 'None', 'Required' => property[:required],
        'ReturnType' => widget_return_type(property[:return_type]),
        'SelectableObjectsProperty' => '',
        'SelectionTypes' => IO::BsonCodec.build_array(property[:selection_types], marker: 1),
        'SetLabel' => false, 'Translations' => widget_translations(property[:translations]),
        'Type' => type
      }
    end

    def object_type(children)
      return if children.empty?

      types = children.map { property_pair(_1).first }
      {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObjectType',
        'PropertyTypes' => IO::BsonCodec.build_array(types, marker: 2)
      }
    end

    def enumeration_values(values)
      IO::BsonCodec.build_array(values.map do |key, caption|
        { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetEnumerationValue',
          '_Key' => key, 'Caption' => caption }
      end, marker: 2)
    end

    def widget_translations(values)
      IO::BsonCodec.build_array(values.map do |language, value|
        { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetTranslation',
          'LanguageCode' => language, 'Text' => value }
      end, marker: 2)
    end

    def widget_return_type(value)
      return unless value

      { '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetReturnType',
        'AssignableTo' => value[:assignable_to], 'EntityProperty' => '',
        'IsList' => false, 'Type' => value[:type] }
    end

    def widget_value(value_type, property) # rubocop:disable Metrics/MethodLength
      value = {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetValue',
        'Action' => { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$NoAction',
                      'DisabledDuringExecution' => true },
        'AttributeRef' => nil, 'DataSource' => nil, 'EntityRef' => nil, 'Expression' => '',
        'Form' => '', 'Icon' => nil, 'Image' => '', 'Microflow' => '', 'Nanoflow' => '',
        'Objects' => IO::BsonCodec.build_array([], marker: 2), 'PrimitiveValue' => '',
        'Selection' => 'None', 'SourceVariable' => nil, 'TextTemplate' => nil,
        'TranslatableValue' => nil, 'TypePointer' => value_type.fetch('$ID'),
        'Widgets' => IO::BsonCodec.build_array([], marker: 2), 'XPathConstraint' => ''
      }
      default_widget_value(value, property)
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
    def default_widget_value(value, property)
      case property[:type]
      when 'Boolean' then value['PrimitiveValue'] = property[:default].empty? ? 'false' : property[:default]
      when 'Integer' then value['PrimitiveValue'] = property[:default].empty? ? '0' : property[:default]
      when 'Enumeration' then value['PrimitiveValue'] = property[:default]
      when 'Expression' then value['Expression'] = property[:default]
      when 'TextTemplate'
        value['TextTemplate'] = client_template(property[:translations]) \
          if property[:required] || !property[:default].empty? || !property[:translations].empty?
      end
      value
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

    def client_template(translations)
      items = translations.map do |language, value|
        { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
          'LanguageCode' => language, 'Text' => value }
      end
      { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ClientTemplate',
        'Fallback' => { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
                        'Items' => IO::BsonCodec.build_array([]) },
        'Parameters' => IO::BsonCodec.build_array([], marker: 2),
        'Template' => { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Text',
                        'Items' => IO::BsonCodec.build_array(items) } }
    end

    def elements(root, name)
      found = []
      root&.each_recursive { found << _1 if _1.is_a?(REXML::Element) && _1.name == name }
      found
    end

    def element_names(root, name) = elements(root, name).filter_map { _1.attributes['name'] }

    def nested_elements(root, container, name)
      wrapper = child(root, container)
      wrapper ? wrapper.elements.to_a.select { _1.name == name } : []
    end

    def nested_element_names(root, container, name)
      nested_elements(root, container, name).filter_map { _1.attributes['name'] }
    end

    def child(root, name) = root.elements.to_a.find { _1.name == name }

    def text(root, name) = child(root, name)&.text.to_s.strip
  end
end
