# frozen_string_literal: true

require 'json'
require 'digest'

module Mxrb
  # Extracts the model schema embedded in a Studio Pro web editor bundle.
  # The resulting catalog is tooling input; public Ruby project sources are
  # generated as typed DSL objects and never expose these internal hashes.
  class StudioSchemaCatalog # rubocop:disable Metrics/ClassLength
    Definition = Data.define(
      :variable, :base_variable, :kind, :name, :abstract, :properties, :values
    )

    DEFINITION_PATTERN = /
      (?<variable>[A-Za-z_$][\w$]*)=
      (?<base>[A-Za-z_$][\w$.]*)\.(?<kind>enum|element|extend)\(\{
      type:(?<library>[A-Za-z_$][\w$]*)\.schemaType\(
      (?<namespace>[A-Za-z_$][\w$]*),"(?<name>[^"]+)"\)
    /x
    ANCHORS = %w[Widget Page DataView].freeze
    EXTERNAL_SCHEMA_TYPES = {
      'attributeRefSchema' => 'AttributeReference',
      'conditionSchema' => 'Condition',
      'dataTypeSchema' => 'DataType',
      'entityRefSchema' => 'EntityReference',
      'microflowExpressionSchema' => 'Expression',
      'textSchema' => 'Text',
      'textTemplateSchema' => 'TextTemplate',
      'xPathConstraintSchema' => 'XPathConstraint'
    }.freeze
    DOCUMENT_PROPERTIES = [
      { name: 'name', declared_by: 'Projects.Document', type: 'string', targets: [],
        cardinality: 'one', optional: false, default: false },
      { name: 'documentation', declared_by: 'Projects.Document', type: 'string', targets: [],
        cardinality: 'one', optional: false, default: false },
      { name: 'excluded', declared_by: 'Projects.Document', type: 'boolean', targets: [],
        cardinality: 'one', optional: false, default: false },
      { name: 'exportLevel', declared_by: 'Projects.Document', type: 'ExportLevel', targets: [],
        cardinality: 'one', optional: false, default: true,
        default_value: { kind: 'literal', value: 'Hidden' } }
    ].map(&:freeze).freeze

    def self.extract(path, mendix_version: nil)
      source_text = File.binread(path)
      new(
        source_text,
        source: File.basename(path),
        mendix_version:,
        source_sha256: Digest::SHA256.hexdigest(source_text)
      ).extract
    end

    def initialize(source_text, source: nil, mendix_version: nil, source_sha256: nil)
      @source_text = source_text
      @source = source
      @mendix_version = mendix_version
      @source_sha256 = source_sha256
    end

    def extract
      selected = select_schema_group
      definitions = include_external_ancestors(selected).map { definition(_1) }
      catalog_payload(definitions)
    end

    private

    def catalog_payload(definitions) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      by_variable = definitions.to_h { [_1.variable, _1.name] }
      by_name = definitions.to_h { [_1.name, definition_payload(_1, by_variable)] }
      bridge_document_inheritance!(by_name)
      add_inherited_properties!(by_name)
      {
        source: @source,
        mendix_version: @mendix_version,
        source_sha256: @source_sha256,
        type_count: by_name.size,
        kinds: by_name.values.map { _1.fetch(:kind) }.tally.sort.to_h,
        widget_types: widget_types(by_name),
        types: by_name.sort.to_h
      }
    end

    def bridge_document_inheritance!(types)
      return unless types.key?('FormBase')

      types['ExportLevel'] ||= {
        kind: 'enum', abstract: false, properties: [], values: %w[Hidden API]
      }
      form_base = types.fetch('FormBase')
      form_base[:properties] = DOCUMENT_PROPERTIES.map(&:dup) + form_base.fetch(:properties)
    end

    def matches
      @matches ||= @source_text.to_enum(:scan, DEFINITION_PATTERN).map do
        match = Regexp.last_match
        {
          variable: match[:variable], base: match[:base], kind: match[:kind],
          library: match[:library], namespace: match[:namespace], name: match[:name],
          body_start: @source_text.index('{', match.begin(0)), position: match.begin(0)
        }
      end
    end

    def include_external_ancestors(selected)
      result = selected.dup
      selected_variables = result.to_h { [_1.fetch(:variable), true] }
      pending = result.dup
      until pending.empty?
        child = pending.shift
        base = child.fetch(:base).split('.').first
        next if selected_variables[base]

        ancestor = matches.select do |candidate|
          candidate.fetch(:variable) == base && candidate.fetch(:position) < child.fetch(:position)
        end.max_by { _1.fetch(:position) }
        next unless ancestor

        selected_variables[base] = true
        result << ancestor
        pending << ancestor
      end
      result
    end

    def select_schema_group
      candidates = matches.group_by { [_1.fetch(:library), _1.fetch(:namespace)] }.values
      anchored = candidates.select do |candidate|
        (ANCHORS - candidate.map { _1.fetch(:name) }).empty?
      end
      selected = anchored.max_by(&:size)
      raise ArgumentError, 'Studio schema containing Widget, Page, and DataView was not found' unless selected

      selected
    end

    def definition(match) # rubocop:disable Metrics/AbcSize
      body = balanced_fragment(match.fetch(:body_start), '{', '}')
      fields = object_fields(body)
      properties = fields['properties'] ? object_fields(fields.fetch('properties')) : {}
      values = fields['values'] ? JSON.parse(fields.fetch('values')) : []
      Definition.new(
        match.fetch(:variable), match.fetch(:base), match.fetch(:kind), match.fetch(:name),
        fields['isAbstract'] == '!0', properties, values
      )
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid enum values for #{match.fetch(:name)}: #{e.message}"
    end

    def definition_payload(definition, by_variable)
      base = definition.kind == 'extend' ? by_variable[definition.base_variable] : nil
      {
        kind: definition.kind,
        abstract: definition.abstract,
        base:,
        properties: definition.properties.map do |name, expression|
          property_payload(name, expression, by_variable, declared_by: definition.name)
        end,
        values: definition.values
      }.compact
    end

    def property_payload(name, expression, by_variable, declared_by:) # rubocop:disable Metrics/MethodLength
      targets = expression.scan(/[A-Za-z_$][\w$]*/).filter_map { by_variable[_1] }.uniq
      reference = reference_kind(expression)
      type = property_type(expression, targets, reference)
      default_value = default_value(expression, type)
      {
        name:, declared_by:, type:,
        targets: targets.drop(1), reference:,
        cardinality: expression.match?(/\.list\(/) ? 'many' : 'one',
        optional: expression.include?('.optional()'),
        default: !default_value.nil?, default_value:
      }.compact
    end

    def default_value(expression, type) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/MethodLength
      argument = call_argument(expression, '.default(')
      return unless argument

      case argument
      when '!0' then { kind: 'literal', value: true }
      when '!1' then { kind: 'literal', value: false }
      when /\A-?\d+\z/ then { kind: 'literal', value: argument.to_i }
      when /\A-?(?:\d+\.\d+|\d+e\d+)\z/i then { kind: 'literal', value: argument.to_f }
      when /\A"/ then { kind: 'literal', value: JSON.parse(argument) }
      when /\A\{width:(-?\d+),height:(-?\d+)\}\z/
        { kind: 'size', width: Regexp.last_match(1).to_i, height: Regexp.last_match(2).to_i }
      when /unknownTypeSchema\.create\(\)/
        { kind: 'unknown_data_type' }
      when /\.create\(\)/
        { kind: 'factory', type: }
      else
        raise ArgumentError, "unsupported default expression #{argument.inspect} for #{type}"
      end
    end

    def call_argument(expression, marker)
      marker_start = expression.index(marker)
      return unless marker_start

      opening = marker_start + marker.length - 1
      fragment = balanced_value(expression, opening, '(', ')')
      fragment[1...-1]
    end

    def property_type(expression, targets, reference)
      primitive = expression[/\.(string|integer|boolean|bigInteger|decimal|dateTime|blob|size)\(/, 1]
      primitive || targets.first || external_schema_type(expression) || reference || 'complex'
    end

    def external_schema_type(expression)
      schema = expression[/\.([a-z][A-Za-z0-9]*Schema)\b/, 1]
      EXTERNAL_SCHEMA_TYPES[schema]
    end

    def reference_kind(expression)
      return 'by_name' if expression.include?('.localByNameReference(')
      return 'by_name' if expression.include?('.byNameReference(')
      return 'by_id' if expression.include?('.byIdReference(')
      return 'reference' if expression.match?(/\.reference\(/i)

      nil
    end

    def add_inherited_properties!(types)
      types.each_key do |name|
        types.fetch(name)[:all_properties] = inherited_properties(name, types)
      end
    end

    def inherited_properties(name, types, seen = [])
      raise ArgumentError, "cyclic Studio schema inheritance at #{name}" if seen.include?(name)

      definition = types.fetch(name)
      inherited = if definition[:base] && types.key?(definition[:base])
                    inherited_properties(definition[:base], types, seen + [name])
                  else
                    []
                  end
      (inherited + definition.fetch(:properties)).reverse.uniq { _1.fetch(:name) }.reverse
    end

    def widget_types(types)
      widgets = types.filter_map do |name, definition|
        next unless ancestor?(name, 'Widget', types)

        {
          name:, abstract: definition.fetch(:abstract), base: definition[:base],
          property_count: definition.fetch(:all_properties).size
        }
      end
      widgets.sort_by { _1.fetch(:name) }
    end

    def ancestor?(name, ancestor, types)
      return true if name == ancestor

      base = types.fetch(name)[:base]
      base && types.key?(base) ? ancestor?(base, ancestor, types) : false
    end

    def object_fields(fragment)
      inner = fragment[1...-1]
      split_top_level(inner).to_h do |entry|
        key, value = split_key_value(entry)
        [key.delete_prefix('"').delete_suffix('"'), value]
      end
    end

    def split_key_value(entry)
      index = top_level_separator(entry, ':')
      raise ArgumentError, "invalid Studio schema field #{entry.inspect}" unless index

      [entry[0...index], entry[(index + 1)..]]
    end

    def split_top_level(value)
      indexes = top_level_indexes(value, ',')
      starts = [0, *indexes.map { _1 + 1 }]
      ends = [*indexes, value.length]
      starts.zip(ends).filter_map do |start_index, end_index|
        entry = value[start_index...end_index]
        entry unless entry.empty?
      end
    end

    def top_level_separator(value, separator)
      top_level_indexes(value, separator).first
    end

    def top_level_indexes(value, separator) # rubocop:disable Metrics
      depth = Hash.new(0)
      quote = nil
      escaped = false
      indexes = []
      value.each_char.with_index do |character, index|
        if quote
          if escaped
            escaped = false
          elsif character == '\\'
            escaped = true
          elsif character == quote
            quote = nil
          end
          next
        end
        if %w[' "].include?(character)
          quote = character
        elsif '({['.include?(character)
          depth[character] += 1
        elsif ')}]'.include?(character)
          depth[{ ')' => '(', '}' => '{', ']' => '[' }.fetch(character)] -= 1
        elsif character == separator && depth.values.all?(&:zero?)
          indexes << index
        end
      end
      indexes
    end

    def balanced_fragment(start_index, opening, closing) # rubocop:disable Metrics
      depth = 0
      quote = nil
      escaped = false
      source = @source_text[start_index..]
      source.each_char.with_index do |character, index|
        if quote
          if escaped
            escaped = false
          elsif character == '\\'
            escaped = true
          elsif character == quote
            quote = nil
          end
          next
        end
        if %w[' "].include?(character)
          quote = character
        elsif character == opening
          depth += 1
        elsif character == closing
          depth -= 1
          return source[0..index] if depth.zero?
        end
      end
      raise ArgumentError, "unterminated Studio schema fragment at byte #{start_index}"
    end

    def balanced_value(value, start_index, opening, closing) # rubocop:disable Metrics
      depth = 0
      quote = nil
      escaped = false
      value[start_index..].each_char.with_index do |character, index|
        if quote
          if escaped
            escaped = false
          elsif character == '\\'
            escaped = true
          elsif character == quote
            quote = nil
          end
          next
        end
        quote = character if %w[' "].include?(character)
        depth += 1 if character == opening
        next unless character == closing

        depth -= 1
        return value[start_index, index + 1] if depth.zero?
      end
      raise ArgumentError, "unterminated balanced value at byte #{start_index}"
    end
  end # rubocop:enable Metrics/ClassLength
end
