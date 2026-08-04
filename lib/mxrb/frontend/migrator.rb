# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Frontend
    MigrationIssue = Data.define(:unit_id, :path, :kind, :message)
    MigrationChange = Data.define(
      :unit_id, :before_hash, :before, :after, :widgets, :layout_rows, :design_properties
    )

    # Immutable, fail-closed preview of frontend model migrations.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    class MigrationPlan
      attr_reader :path, :version, :changes, :issues

      def initialize(path:, version:, changes:, issues:)
        @path = path
        @version = version
        @changes = changes.freeze
        @issues = issues.freeze
        @applied = false
      end

      def safe? = issues.empty?
      def applied? = @applied
      def widgets = changes.sum(&:widgets)
      def layout_rows = changes.sum(&:layout_rows)
      def design_properties = changes.sum(&:design_properties)

      def apply!
        raise SerializationError, blocked_message unless safe?
        raise SerializationError, 'frontend migration plan was already applied' if applied?

        mpr = IO::MprFile.open(path)
        mpr.transaction do
          changes.each do |change|
            current = mpr.unit(change.unit_id)
            raise SerializationError, "frontend unit disappeared: #{change.unit_id}" unless current
            raise SerializationError, "frontend unit changed after preview: #{change.unit_id}" unless
              current['ContentsHash'] == change.before_hash

            mpr.update_unit(change.unit_id, change.after)
          end
        end
        @applied = true
        self
      ensure
        mpr&.close
      end

      private

      def blocked_message
        details = issues.map { "#{_1.kind} at #{_1.unit_id}#{_1.path}: #{_1.message}" }
        "frontend migration is blocked: #{details.join('; ')}"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Updates installed pluggable-widget schemas and legacy layout-grid weights
    # directly in an MPR. Package XML is the source of truth; no Studio Pro or
    # mx invocation is involved.
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    # rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity
    # rubocop:disable Lint/NonLocalExitFromIterator
    class Migrator
      SUPPORTED_MAJORS = [10, 11].freeze
      STANDARD_TYPE_KEYS = %w[
        $ID $Type HelpUrl ObjectType OfflineCapable StudioCategory StudioProCategory
        SupportedPlatform WidgetDescription WidgetId WidgetName WidgetNeedsEntityContext
        WidgetPluginWidget
      ].freeze
      STANDARD_OBJECT_KEYS = %w[$ID $Type Properties TypePointer].freeze
      # TabletWeight/PhoneWeight use -1 as a valid responsive inheritance
      # sentinel. CE0535 concerns only the desktop Weight total.
      WEIGHT_KEYS = %w[Weight].freeze
      AUDITED_DATA_GRID_PACKAGE_SHA256 =
        '8eabd99ef927b918dbb2bd5f05cf12dc14026b37e496bc1b0569c34369a0b713'
      ACTIVE_VALUE_FIELDS = {
        'Action' => %w[Action Microflow Nanoflow],
        'Association' => %w[EntityRef SourceVariable],
        'Attribute' => %w[AttributeRef SourceVariable],
        'DataSource' => %w[DataSource XPathConstraint],
        'Expression' => %w[Expression SourceVariable], 'Icon' => %w[Icon],
        'Image' => %w[Image], 'Object' => %w[Objects], 'Selection' => %w[Selection],
        'TextTemplate' => %w[TextTemplate TranslatableValue], 'Widgets' => %w[Widgets]
      }.freeze

      def self.plan(path) = new(path).plan

      def initialize(path)
        @path = File.expand_path(path)
        @root = File.dirname(@path)
        @definitions = {}
      end

      def plan
        mpr = IO::MprFile.open(@path, readonly: true)
        version = mpr.mendix_version.to_s
        issues = []
        unless SUPPORTED_MAJORS.include?(version.to_i)
          issues << MigrationIssue.new('', '', :unsupported_version,
                                       "Mendix #{version.inspect}; supported majors are 10 and 11")
          return MigrationPlan.new(path: @path, version:, changes: [], issues:)
        end
        validate_widget_packages!(issues)

        changes = mpr.all_units.filter_map do |unit|
          before = mpr.parse_contents(unit)
          after = deep_copy(before)
          counts = { widgets: 0, layout_rows: 0, design_properties: 0 }
          migrate_value!(after, unit.fetch('UnitID'), '$', issues, counts)
          next if after == before

          MigrationChange.new(
            unit.fetch('UnitID'), unit.fetch('ContentsHash'), before, after,
            counts.fetch(:widgets), counts.fetch(:layout_rows), counts.fetch(:design_properties)
          )
        end
        MigrationPlan.new(path: @path, version:, changes:, issues:)
      ensure
        mpr&.close
      end

      private

      def migrate_value!(value, unit_id, path, issues, counts)
        case value
        when Hash
          migrate_design_properties!(value, unit_id, path, issues, counts) if value.key?('DesignProperties')
          migrate_layout_row!(value, unit_id, path, issues, counts) if layout_row?(value)
          migrate_widget!(value, unit_id, path, issues, counts) if custom_widget?(value)
          value.each { |key, child| migrate_value!(child, unit_id, "#{path}.#{key}", issues, counts) }
        when Array
          value.each_with_index do |child, index|
            migrate_value!(child, unit_id, "#{path}[#{index}]", issues, counts)
          end
        end
      end

      def migrate_widget!(widget, unit_id, path, issues, counts)
        widget_id = widget.dig('Type', 'WidgetId').to_s
        return if widget_id.empty?

        definition = definition(widget_id)
        unless definition
          kind, message = definition_failure(widget_id)
          return issue(issues, unit_id, path, kind, message)
        end

        new_type, new_object = WidgetPackage.template(definition)
        return unless safe_envelope?(widget, new_type, new_object, unit_id, path, issues)

        migrated = rebind_object(
          widget['Object'], widget.dig('Type', 'ObjectType'),
          new_object, new_type['ObjectType'], unit_id, path, issues
        )
        return unless migrated

        apply_audited_package_migration!(migrated, new_type, package_digest(widget_id))
        schema_changed = canonical_schema(widget['Type']) != canonical_schema(new_type)
        object_changed = canonical_schema(widget['Object']) != canonical_schema(migrated)
        return unless schema_changed || object_changed

        widget['Type'] = new_type
        widget['Object'] = migrated
        counts[:widgets] += 1
      end

      def safe_envelope?(widget, new_type, new_object, unit_id, path, issues)
        old_type = widget['Type']
        old_object = widget['Object']
        return issue(issues, unit_id, path, :malformed_widget, 'missing Type or Object') unless
          old_type.is_a?(Hash) && old_object.is_a?(Hash)

        extra_type = old_type.keys - STANDARD_TYPE_KEYS - new_type.keys
        extra_object = old_object.keys - STANDARD_OBJECT_KEYS - new_object.keys
        if extra_type.any?
          return issue(issues, unit_id, path, :unknown_widget_schema,
                       "unrecognized Type fields: #{extra_type.sort.join(', ')}")
        end
        if extra_object.any?
          return issue(issues, unit_id, path, :unknown_widget_object,
                       "unrecognized Object fields: #{extra_object.sort.join(', ')}")
        end

        true
      end

      def rebind_object(old_object, old_type, new_object, new_type, unit_id, path, issues)
        old_types = property_types(old_type)
        new_types = property_types(new_type)
        old_by_pointer = old_types.to_h { [id(_1['$ID']), _1] }
        new_by_key = new_types.to_h { [_1['PropertyKey'].to_s, _1] }
        old_values = property_values(old_object)
        rebound = {}

        old_values.each do |property|
          old_property_type = old_by_pointer[id(property['TypePointer'])]
          unless old_property_type
            return issue(issues, unit_id, path, :unknown_property_pointer,
                         "property pointer #{id(property['TypePointer']).inspect} is not in WidgetType")
          end

          key = old_property_type['PropertyKey'].to_s
          new_property_type = new_by_key[key]
          old_value_type = old_property_type['ValueType'] || {}
          unless new_property_type
            next if default_widget_value?(property['Value'], old_value_type)

            return issue(issues, unit_id, path, :removed_configured_widget_property,
                         "installed schema removed configured property #{key.inspect}")
          end

          new_value_type = new_property_type['ValueType'] || {}
          value = if old_value_type['Type'] == new_value_type['Type']
                    rebind_value(
                      property['Value'], old_value_type, new_value_type,
                      unit_id, "#{path}.#{key}", issues
                    )
                  else
                    convert_value(
                      property['Value'], old_value_type, new_value_type,
                      unit_id, "#{path}.#{key}", issues
                    )
                  end
          return unless value

          rebound[key] = deep_copy(property).merge(
            'TypePointer' => new_property_type['$ID'], 'Value' => value
          )
        end

        result = deep_copy(new_object)
        result['$ID'] = old_object['$ID'] if old_object.key?('$ID')
        defaults = property_values(new_object).to_h do |property|
          type = new_types.find { id(_1['$ID']) == id(property['TypePointer']) }
          property = neutral_new_property(property, type)
          [type.fetch('PropertyKey').to_s, property]
        end
        clear_inactive_default_captions!(rebound, new_by_key)
        added = new_types.filter_map do |type|
          key = type['PropertyKey'].to_s
          defaults[key] unless rebound.key?(key)
        end
        # Studio Pro preserves the previous object-property order and appends
        # newly introduced properties, even when their schema declaration is
        # located in the middle of the XML. CE0463 checks that storage order.
        values = rebound.values + added
        result['Properties'] = IO::BsonCodec.build_array(values, marker: array_marker(new_object['Properties']))
        result
      end

      def neutral_new_property(property, _type) = deep_copy(property)

      def clear_inactive_default_captions!(properties, types)
        properties.each do |key, property|
          next unless key.end_with?('Caption') && property.dig('Value', 'TextTemplate')

          controller = properties[key.delete_suffix('Caption')]
          next unless controller&.dig('Value', 'PrimitiveValue') == 'false'

          value_type = types.dig(key, 'ValueType')
          next unless canonical_schema(property['Value']) == canonical_schema(default_value(value_type))

          replacement = default_value(value_type)
          replacement['$ID'] = property.dig('Value', '$ID')
          replacement['TypePointer'] = value_type['$ID']
          replacement['TextTemplate'] = nil
          property['Value'] = replacement
        end
      end

      def rebind_value(old_value, old_type, new_type, unit_id, path, issues)
        return issue(issues, unit_id, path, :malformed_widget_value, 'property Value is not an object') unless
          old_value.is_a?(Hash)

        result = normalized_value(old_value, new_type)
        result['TypePointer'] = new_type['$ID']
        return result unless old_type['Type'] == 'Object'

        objects = array_items(old_value['Objects'])
        if objects.empty?
          result['Objects'] = IO::BsonCodec.build_array([], marker: array_marker(old_value['Objects']))
          return result
        end

        old_object_type = old_type['ObjectType']
        new_object_type = new_type['ObjectType']
        unless old_object_type.is_a?(Hash) && new_object_type.is_a?(Hash)
          return issue(issues, unit_id, path, :changed_widget_object,
                       'nested Object schema is unavailable')
        end

        objects = objects.map.with_index do |object, index|
          rebound = rebind_object(
            object, old_object_type, object_template(new_object_type), new_object_type,
            unit_id, "#{path}[#{index}]", issues
          )
          return unless rebound

          rebound
        end
        result['Objects'] = IO::BsonCodec.build_array(objects, marker: array_marker(old_value['Objects']))
        result
      end

      def normalized_value(old_value, value_type)
        result = default_value(value_type)
        fields = ACTIVE_VALUE_FIELDS.fetch(value_type['Type'], %w[PrimitiveValue])
        fields.each do |field|
          result[field] = normalize_source_variable(deep_copy(old_value[field])) if old_value.key?(field)
        end
        preserve_ids!(result, old_value)
        result
      end

      def convert_value(old_value, old_type, new_type, unit_id, path, issues)
        if old_type['Type'] == 'Boolean' && new_type['Type'] == 'Expression'
          primitive = old_value&.fetch('PrimitiveValue', nil)
          if %w[true false].include?(primitive) && boolean_value_only?(old_value, old_type)
            result = default_value(new_type)
            result['Expression'] = primitive
            result['TypePointer'] = new_type['$ID']
            preserve_ids!(result, old_value)
            return result
          end
        end

        issue(
          issues, unit_id, path, :changed_widget_property,
          "property changed from #{old_type['Type']} to #{new_type['Type']} without a lossless conversion"
        )
      end

      def boolean_value_only?(value, value_type)
        expected = default_value(value_type)
        actual = deep_copy(value)
        actual['PrimitiveValue'] = expected['PrimitiveValue']
        canonical_schema(actual) == canonical_schema(expected)
      end

      def object_template(object_type)
        properties = property_types(object_type).reject { _1.dig('ValueType', 'Type') == 'System' }.map do |type|
          value_type = type.fetch('ValueType')
          property = {
            type: value_type.fetch('Type'), default: value_type.fetch('DefaultValue', '').to_s,
            translations: [], required: value_type.fetch('Required', false),
            selection_types: array_items(value_type['SelectionTypes'])
          }
          {
            '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetProperty',
            'TypePointer' => type['$ID'],
            'Value' => WidgetPackage.allocate.send(:widget_value, value_type, property)
          }
        end
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObject',
          'Properties' => IO::BsonCodec.build_array(properties, marker: 2),
          'TypePointer' => object_type['$ID']
        }
      end

      def default_widget_value?(value, value_type)
        canonical_schema(value) == canonical_schema(default_value(value_type))
      end

      def default_value(value_type)
        translations = array_items(value_type['Translations']).map do |translation|
          [translation['LanguageCode'].to_s, translation['Text'].to_s]
        end
        property = {
          type: value_type.fetch('Type'), default: value_type.fetch('DefaultValue', '').to_s,
          translations:, required: value_type.fetch('Required', false),
          selection_types: array_items(value_type['SelectionTypes'])
        }
        WidgetPackage.allocate.send(:widget_value, value_type, property)
      end

      def migrate_layout_row!(row, unit_id, path, issues, counts)
        columns = array_items(row['Columns'])
        return if columns.empty?

        replacements = {}
        WEIGHT_KEYS.each do |key|
          values = columns.map { _1[key] }
          next if values.all? { _1.is_a?(Integer) && _1.positive? } && values.sum == 12

          normalized = normalize_weights(values)
          unless normalized
            return issue(issues, unit_id, path, :unsafe_layout_weights,
                         "#{key} values cannot be normalized safely: #{values.inspect}")
          end

          replacements[key] = normalized
        end
        return if replacements.empty?

        replacements.each do |key, values|
          columns.each_with_index { |column, index| column[key] = values.fetch(index) }
        end
        counts[:layout_rows] += 1
      end

      def migrate_design_properties!(owner, unit_id, path, issues, counts)
        raw = owner['DesignProperties']
        items = array_items(raw)
        mapping = spacing_mappings
        return if items.empty?

        changed = migrate_simple_design_aliases!(items)
        retained = []
        compounds = items.select { compound_design_property?(_1) }.to_h { [_1['Key'], _1] }
        items.each do |item|
          old_name = design_property_name(item)
          target = mapping[old_name]
          unless target
            retained << item
            next
          end

          compound = compounds[target.fetch(:key)] ||= compound_design_property(target.fetch(:key))
          properties = array_items(compound.dig('Value', 'Properties'))
          existing = properties.find { _1['Key'] == target.fetch(:child) }
          if existing && existing.dig('Value', 'Option') != target.fetch(:option)
            issue(issues, unit_id, path, :conflicting_design_property,
                  "#{old_name.inspect} conflicts with #{target.fetch(:child).inspect}")
            retained << item
            next
          end
          unless existing
            properties << option_design_property(target.fetch(:child), target.fetch(:option))
            compound['Value']['Properties'] = IO::BsonCodec.build_array(properties, marker: 2)
          end
          retained << compound unless retained.include?(compound)
          changed += 1
        end
        return if changed.zero?

        owner['DesignProperties'] = IO::BsonCodec.build_array(retained, marker: array_marker(raw))
        counts[:design_properties] += changed
      end

      def spacing_mappings
        return @spacing_mappings if defined?(@spacing_mappings)

        mappings = {}
        Dir.glob(File.join(@root, 'themesource', '*', '{web,native}', 'design-properties.json')).sort.each do |path|
          document = JSON.parse(File.read(path))
          document.each_value do |properties|
            Array(properties).each { collect_spacing_mappings(_1, mappings) }
          end
        rescue JSON::ParserError
          next
        end
        @spacing_mappings = mappings
      end

      def migrate_simple_design_aliases!(items)
        mappings = design_alias_mappings
        items.count do |item|
          option = item.dig('Value', 'Option')
          target = mappings[[item['Key'], option]]
          next false unless target

          item['Key'] = target.fetch(:key)
          item['Value']['Option'] = target.fetch(:option) if target.key?(:option)
          true
        end
      end

      def design_alias_mappings
        return @design_alias_mappings if defined?(@design_alias_mappings)

        mappings = {}
        design_property_documents.each do |document|
          document.each_value do |properties|
            Array(properties).each { collect_design_aliases(_1, mappings) }
          end
        end
        @design_alias_mappings = mappings.reject { |_key, value| value == :conflict }
      end

      def design_property_documents
        paths = Dir.glob(File.join(@root, 'themesource', '*', '{web,native}', 'design-properties.json')).sort
        paths.filter_map do |path|
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end
      end

      def collect_design_aliases(property, mappings)
        return unless property.is_a?(Hash) && property['name'] && property['type'] != 'Spacing'

        new_key = property.fetch('name')
        old_keys = Array(property['oldNames'])
        options = Array(property['options'])
        old_keys.each { add_design_alias(mappings, [_1, nil], key: new_key) }
        options.each do |option|
          new_option = option['name']
          old_options = Array(option['oldNames'])
          old_options.each { add_design_alias(mappings, [new_key, _1], key: new_key, option: new_option) }
          old_keys.each { add_design_alias(mappings, [_1, new_option], key: new_key, option: new_option) }
          old_keys.product(old_options).each do |old_key, old_option|
            add_design_alias(mappings, [old_key, old_option], key: new_key, option: new_option)
          end
        end
      end

      def add_design_alias(mappings, source, target)
        mappings[source] = :conflict if mappings.key?(source) && mappings[source] != target
        mappings[source] ||= target.freeze
      end

      def collect_spacing_mappings(property, mappings)
        return unless property.is_a?(Hash) && property['type'] == 'Spacing'

        %w[margin padding].each do |mode|
          Array(property[mode]).each do |size|
            %w[top right bottom left].each do |direction|
              Array(size.dig(direction, 'oldNames')).each do |old_name|
                target = {
                  key: property.fetch('name'), child: "#{mode}-#{direction}",
                  option: size.fetch('name')
                }.freeze
                mappings[old_name] = target if !mappings.key?(old_name) || mappings[old_name] == target
              end
            end
          end
        end
      end

      def design_property_name(item)
        return unless item.is_a?(Hash) && item.dig('Value', '$Type') == 'Forms$OptionDesignPropertyValue'

        "#{item['Key']}::#{item.dig('Value', 'Option')}"
      end

      def compound_design_property?(item)
        item.is_a?(Hash) && item.dig('Value', '$Type') == 'Forms$CompoundDesignPropertyValue'
      end

      def compound_design_property(key)
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DesignPropertyValue', 'Key' => key,
          'Value' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$CompoundDesignPropertyValue',
            'Properties' => IO::BsonCodec.build_array([], marker: 2)
          }
        }
      end

      def option_design_property(key, option)
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DesignPropertyValue', 'Key' => key,
          'Value' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$OptionDesignPropertyValue', 'Option' => option
          }
        }
      end

      def normalize_weights(values)
        return unless values.all? { _1.is_a?(Integer) && !_1.zero? }

        positive_total = values.select(&:positive?).sum
        return if positive_total >= 12 && values.any?(&:negative?)
        return if positive_total > 12

        negative = values.each_index.select { values[_1].negative? }
        return if negative.empty?

        available = 12 - positive_total
        weights = negative.map { values[_1].abs }
        allocated = apportion(available, weights)
        return if allocated.any?(&:zero?)

        values.map.with_index { |value, index| value.positive? ? value : allocated.fetch(negative.index(index)) }
      end

      def apportion(total, weights)
        denominator = weights.sum
        exact = weights.map { Rational(total * _1, denominator) }
        result = exact.map(&:floor)
        remaining = total - result.sum
        order = exact.each_index.sort_by { |index| [-(exact[index] - result[index]), index] }
        order.first(remaining).each { result[_1] += 1 }
        result
      end

      def definition(widget_id)
        return @definitions[widget_id] if @definitions.key?(widget_id)

        @package_digests ||= {}
        matches = valid_widget_package_paths.filter_map do |package_path|
          found = WidgetPackage.new(package_path).definition(widget_id)
          [package_path, found] if found
        rescue Zip::Error, REXML::ParseException => e
          @invalid_widget_packages ||= {}
          @invalid_widget_packages[package_path] = e
          nil
        end
        if matches.one?
          package_path, found = matches.first
          @package_digests[widget_id] = Digest::SHA256.file(package_path).hexdigest
          return @definitions[widget_id] = found
        end

        @definition_failures ||= {}
        @definition_failures[widget_id] = if matches.empty?
                                            [:missing_widget_definition,
                                             "no installed MPK defines #{widget_id.inspect}"]
                                          else
                                            paths = matches.map { relative_package_path(_1.first) }
                                            [:ambiguous_widget_definition,
                                             "multiple installed MPKs define #{widget_id.inspect}: " \
                                             "#{paths.join(', ')}"]
                                          end
        @definitions[widget_id] = nil
      end

      def definition_failure(widget_id)
        @definition_failures&.fetch(
          widget_id, [:missing_widget_definition, "no installed MPK defines #{widget_id.inspect}"]
        )
      end

      def validate_widget_packages!(issues)
        @invalid_widget_packages = {}
        widget_package_paths.each do |package_path|
          WidgetPackage.new(package_path).definition('__mxrb_package_validation__')
        rescue Zip::Error, REXML::ParseException => e
          @invalid_widget_packages[package_path] = e
          issue(
            issues, '', ".widgets.#{File.basename(package_path)}", :invalid_widget_package,
            "cannot read #{relative_package_path(package_path)}: #{e.class}: #{e.message}"
          )
        end
      end

      def widget_package_paths
        @widget_package_paths ||= Dir.glob(File.join(@root, 'widgets', '*.mpk')).sort
      end

      def valid_widget_package_paths
        invalid = @invalid_widget_packages || {}
        widget_package_paths.reject { invalid.key?(_1) }
      end

      def relative_package_path(path)
        Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
      end

      def package_digest(widget_id)
        @package_digests&.fetch(widget_id, nil)
      end

      def apply_audited_package_migration!(object, type, digest)
        return unless digest == AUDITED_DATA_GRID_PACKAGE_SHA256

        types = property_types(type['ObjectType']).to_h { [_1['PropertyKey'], _1] }
        properties = property_values(object).each_with_object({}) do |property, result|
          property_type = types.values.find { id(_1['$ID']) == id(property['TypePointer']) }
          result[property_type['PropertyKey']] = property if property_type
        end
        pagination = properties.dig('pagination', 'Value', 'PrimitiveValue')
        selection = properties.dig('itemSelection', 'Value', 'Selection')
        clear_text_template!(properties['loadMoreButtonCaption']) unless pagination == 'loadMore'
        clear_text_template!(properties['clearSelectionButtonLabel']) unless selection == 'Multi'
        clear_text_template!(properties['singleSelectionColumnLabel']) unless selection == 'Single'
        clear_audited_data_grid_column_texts!(properties['columns'], types['columns'])
      end

      def clear_text_template!(property)
        property['Value']['TextTemplate'] = nil if property
      end

      def clear_audited_data_grid_column_texts!(columns_property, columns_type)
        return unless columns_property && columns_type

        object_type = columns_type.dig('ValueType', 'ObjectType')
        types = property_types(object_type).to_h { [id(_1['$ID']), _1] }
        array_items(columns_property.dig('Value', 'Objects')).each do |column|
          values = property_values(column).each_with_object({}) do |property, result|
            type = types[id(property['TypePointer'])]
            result[type['PropertyKey']] = property if type
          end
          content = values.dig('showContentAs', 'Value', 'PrimitiveValue')
          clear_text_template!(values['dynamicText']) unless content == 'dynamicText'
          clear_text_template!(values['exportValue']) unless content == 'customContent'
          clear_text_template!(values['tooltip']) if content == 'customContent'
        end
      end

      def property_types(type) = array_items(type&.fetch('PropertyTypes', nil))
      def property_values(object) = array_items(object&.fetch('Properties', nil))
      def array_items(value) = IO::BsonCodec.parse_array(value)[:items]
      def array_marker(value) = IO::BsonCodec.parse_array(value)[:marker]
      def id(value) = IO::BsonCodec.extract_id(value)
      def custom_widget?(value) = value['$Type'] == 'CustomWidgets$CustomWidget'
      def layout_row?(value) = value['$Type'] == 'Forms$LayoutGridRow'

      def canonical_schema(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if ['$ID', 'TypePointer'].include?(key)

            result[key] = canonical_schema(child)
          end
        when Array
          value.map { canonical_schema(_1) }
        else value
        end
      end

      def issue(issues, unit_id, path, kind, message)
        issues << MigrationIssue.new(unit_id, path, kind, message)
        false
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, child| [key, deep_copy(child)] }
        when Array then value.map { deep_copy(_1) }
        else value
        end
      end

      def preserve_ids!(target, source)
        case target
        when Hash
          return target unless source.is_a?(Hash)

          target['$ID'] = source['$ID'] if target.key?('$ID') && source.key?('$ID')
          target.each do |key, child|
            preserve_ids!(child, source[key]) if source.key?(key) && key != 'TypePointer'
          end
        when Array
          return target unless source.is_a?(Array)

          target.zip(source).each { |child, old_child| preserve_ids!(child, old_child) }
        end
        target
      end

      def normalize_source_variable(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[key] = normalize_source_variable(child)
            if value['$Type'] == 'Forms$PageVariable' && !value.key?('SubKey') && key == 'SnippetParameter'
              result['SubKey'] = ''
            elsif value['$Type'] == 'Forms$CallNanoflowClientAction' && !value.key?('OutputMappings') &&
                  key == 'Nanoflow'
              result['OutputMappings'] = IO::BsonCodec.build_array([], marker: 3)
            elsif value['$Type'] == 'Forms$MicroflowSettings' && !value.key?('OutputMappings') &&
                  key == 'Microflow'
              result['OutputMappings'] = IO::BsonCodec.build_array([], marker: 3)
            end
          end
        when Array then value.map { normalize_source_variable(_1) }
        else value
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength
    # rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity
    # rubocop:enable Lint/NonLocalExitFromIterator
  end
end
