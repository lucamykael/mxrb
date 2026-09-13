# frozen_string_literal: true

require 'json'

module Mxrb
  # Typed, immutable view of the canonical Mendix Forms metamodel.
  module Forms
    # Converts exact metamodel identifiers into conventional Ruby method names.
    module Naming
      module_function

      def ruby_name(name)
        normalized = name.to_s
                         .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
                         .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                         .tr('-', '_')
                         .downcase
        normalized == 'class' ? 'css_class' : normalized
      end
    end

    Size = Data.define(:width, :height)
    DefaultValue = Data.define(:kind, :value)

    Property = Data.define(
      :name, :ruby_name, :declared_by, :type_name, :targets, :cardinality, :optional,
      :default_value, :reference
    ) do
      def many? = cardinality == :many
      def one? = !many?
      def optional? = optional
      def required? = !optional?
      def default? = !default_value.nil?
      def reference? = !reference.nil?
    end

    Type = Data.define(
      :name, :ruby_name, :kind, :abstract, :base_name, :properties, :all_properties,
      :values, :widget
    ) do
      def enum? = kind == :enum
      def element? = !enum?
      def abstract? = abstract
      def widget? = widget
      def concrete? = element? && !abstract?

      def property(identifier, inherited: true)
        candidates = inherited ? all_properties : properties
        return identifier if identifier.is_a?(Property) && candidates.include?(identifier)

        ruby_identifier = Naming.ruby_name(identifier)
        candidates.find { _1.name == identifier.to_s || _1.ruby_name == ruby_identifier }
      end

      def fetch_property(identifier, inherited: true)
        property(identifier, inherited:) || raise(KeyError, "unknown #{name} property #{identifier.inspect}")
      end
    end

    # Loads a versioned schema without leaking its JSON/hash transport into the
    # public API. Consumers work with Type and Property values only.
    class Catalog
      ROOT = File.expand_path('../compiler/schemas', __dir__)
      FILES = { '11.12.1' => 'forms-11.12.1.json' }.freeze

      @catalogs = {}
      @catalog_mutex = Mutex.new

      attr_reader :version, :source, :source_sha256, :types

      def self.for(version)
        version = version.to_s
        filename = FILES.fetch(version) do
          raise ArgumentError, "unsupported Forms schema #{version.inspect}; available: #{FILES.keys.join(', ')}"
        end
        @catalog_mutex.synchronize do
          @catalogs[version] ||= new(File.join(ROOT, filename), expected_version: version)
        end
      end

      def initialize(path, expected_version: nil) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        payload = JSON.parse(File.read(path))
        @version = payload.fetch('mendix_version').dup.freeze
        if expected_version && @version != expected_version
          raise ArgumentError, "Forms schema version mismatch: expected #{expected_version}, got #{@version.inspect}"
        end

        @source = payload.fetch('source').dup.freeze
        @source_sha256 = payload.fetch('source_sha256').dup.freeze
        widget_names = payload.fetch('widget_types').to_h { [_1.fetch('name'), true] }
        @types = payload.fetch('types').map do |name, definition|
          build_type(name, definition, widget_names.key?(name))
        end.sort_by(&:name).freeze
        @types_by_name = @types.to_h { [_1.name, _1] }.freeze
        @types_by_ruby_name = @types.to_h { [_1.ruby_name, _1] }.freeze
        freeze
      end

      def type(identifier)
        @types_by_name[identifier.to_s] || @types_by_ruby_name[Naming.ruby_name(identifier)]
      end

      def fetch_type(identifier)
        type(identifier) || raise(KeyError, "unknown Forms type #{identifier.inspect} for Mendix #{version}")
      end

      def widgets(concrete: nil)
        selected = types.select(&:widget?)
        selected = selected.select(&:concrete?) if concrete == true
        selected = selected.reject(&:concrete?) if concrete == false
        selected.freeze
      end

      def concrete_widgets = widgets(concrete: true)
      def enum_types = types.select(&:enum?).freeze
      def property_occurrences = concrete_widgets.sum { _1.all_properties.size }

      def descendant?(candidate, ancestor)
        current = fetch_type(candidate)
        ancestor = fetch_type(ancestor)
        until current.base_name.nil?
          return true if current.base_name == ancestor.name

          current = fetch_type(current.base_name)
        end
        false
      end

      private

      def build_type(name, definition, widget) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        Type.new(
          name.dup.freeze,
          Naming.ruby_name(name).freeze,
          definition.fetch('kind').to_sym,
          definition.fetch('abstract'),
          definition['base']&.dup&.freeze,
          build_properties(definition.fetch('properties')),
          build_properties(definition.fetch('all_properties')),
          definition.fetch('values').map { _1.dup.freeze }.freeze,
          widget
        )
      end

      def build_properties(definitions) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        definitions.map do |definition|
          Property.new(
            definition.fetch('name').dup.freeze,
            Naming.ruby_name(definition.fetch('name')).freeze,
            definition.fetch('declared_by').dup.freeze,
            definition.fetch('type').dup.freeze,
            definition.fetch('targets').map { _1.dup.freeze }.freeze,
            definition.fetch('cardinality').to_sym,
            definition.fetch('optional'),
            build_default(definition['default_value']),
            definition['reference']&.to_sym
          )
        end.freeze
      end

      def build_default(definition)
        return unless definition

        kind = definition.fetch('kind').to_sym
        value = case kind
                when :literal then definition['value']
                when :size then Size.new(definition.fetch('width'), definition.fetch('height'))
                when :factory then definition.fetch('type').dup.freeze
                end
        value = value.dup.freeze if value.is_a?(String)
        DefaultValue.new(kind, value)
      end
    end
  end
end
