# frozen_string_literal: true

require 'digest'
require_relative 'oql_predicate'
require_relative 'oql_view_query'
require_relative 'oql_relational_view'
require_relative 'oql_projection_view'

module Mxrb
  module Runtime
    # Read-only projections over durable rows. OQL text is parsed into a small
    # supported grammar; it is never passed to SQLite as executable SQL.
    class OqlViews
      Definition = Data.define(:name, :columns)
      Column = Data.define(:name, :type)

      # Another view read as a source table; its rows are the view's objects.
      class Table
        attr_reader :definition

        def initialize(definition, &read)
          @definition = definition
          @read = read
        end

        def rows = @rows ||= @read.call
      end

      def initialize(project, store, decoder:)
        @store = store
        @decoder = decoder
        @decimal = DecimalContext.new(**DecimalContext.settings(project).transform_keys(&:to_sym))
        @definitions = project.modules.flat_map do |mod|
          mod.entities.filter_map do |entity|
            next unless entity.respond_to?(:oql_view?) && entity.oql_view?

            ["#{mod.name}.#{entity.name}", [entity, mod]]
          end
        end.to_h
        @reading = []
      end

      def include?(name) = @definitions.key?(name.to_s)

      def reject_writes!(values)
        Array(values).compact.each do |value|
          raise NativeRuntimeError, "OQL view #{value.entity} is read-only" if include?(value.entity)
        end
      end

      def retrieve(name)
        entity, mod = @definitions.fetch(name.to_s)
        text = query(entity, mod)
        return OqlProjectionView.new(@store, decoder: @decoder).retrieve(name, entity, text) unless relational?(text)

        reading(name.to_s) do
          OqlRelationalView.new(text, @store, decoder: @decoder, decimal: @decimal, sources: method(:table))
                           .retrieve(name.to_s, entity)
        end
      end

      def table(name)
        return unless include?(name)

        entity, = @definitions.fetch(name)
        columns = entity.attributes.map { Column.new(_1.name.to_s, _1.type.to_sym) }
        Table.new(Definition.new(name, columns)) do
          retrieve(name).map { |object| object.members.merge('ID' => object.id, '__entity' => name) }
        end
      end

      def associated(definition, start)
        unless start.entity == definition.from_entity
          raise NativeRuntimeError, 'OQL view associations are navigable only from the view'
        end

        Array(start.members[definition.name]).compact
      end

      private

      def relational?(text)
        tokens = Oql::Translator.tokens(text).reject { _1.type == :space }
        OqlRelationalQuery.relational?(text) ||
          tokens.each_cons(3).any? { |mod, dot, name| dot.text == '.' && include?("#{mod.text}.#{name.text}") }
      end

      def reading(name)
        raise NativeRuntimeError, "OQL view #{name} reads itself" if @reading.include?(name)

        @reading.push(name)
        yield
      ensure
        @reading.pop if @reading.last == name
      end

      def query(entity, mod)
        return entity.oql_query unless entity.oql_query.to_s.empty?
        return '' unless entity.respond_to?(:oql_source_document) && mod.respond_to?(:oql_view_documents)

        name = entity.oql_source_document.to_s.split('.').last
        document = mod.oql_view_documents.find { _1.fetch(:name) == name }
        document&.dig(:doc, 'Oql').to_s
      end
    end
  end
end
