# frozen_string_literal: true

require_relative 'oql_datasets'

module Mxrb
  module Runtime
    # ExecuteOQLStatement and CountRowsOQLStatement of the Marketplace OQL module:
    # a dataset name or OQL text with $parameters, an amount and an offset. Each
    # column fills an attribute of the same name or, for object IDs, an owned
    # association named Module.Column; unknown columns are errors, as in the module.
    class OqlModuleQuery
      RESERVED = /\A(.+\.ID|submetaobjectname)\z/

      def initialize(datasets, store)
        @datasets = datasets
        @store = store
      end

      def objects(statement, entity_name, parameters:, amount: nil, offset: nil)
        attributes = @datasets.entity(entity_name).attributes.map(&:name)
        table = @datasets.query(@datasets.dataset_text(statement) || statement, parameters:)
        types = table.definition.columns.to_h { [_1.name, _1.type] }
        page(table.rows, amount, offset).map { |row| instantiate(entity_name, row, attributes, types) }
      end

      def count(statement, parameters:, amount: nil)
        page(@datasets.query(statement, parameters:).rows, amount, nil).length
      end

      private

      def page(rows, amount, offset)
        rows = rows.drop(offset.to_i)
        amount.to_i.positive? ? rows.take(amount) : rows
      end

      def instantiate(entity_name, row, attributes, types)
        @store.create(entity_name).tap do |object|
          row.each do |column, value|
            next if RESERVED.match?(column)

            if types[column] == :identifier && value then link(object, column, value)
            else assign(object, column, value, attributes)
            end
          end
        end
      end

      # An attribute takes any value; an empty value may also leave an association unset.
      def assign(object, column, value, attributes)
        return object.members[column] = value if attributes.include?(column)
        return if value.nil? && association(object.entity, column)

        raise NativeRuntimeError, "Could not find result attribute #{column} in target object."
      end

      def link(object, column, id)
        association = association(object.entity, column)
        raise NativeRuntimeError, "Could not find result association #{column} in target object." unless association

        object.members[association.name] = @store.find(association.to_entity, id)
      end

      def association(entity, column)
        pattern = /\A[^.]+\.#{Regexp.escape(column)}\z/
        @store.schema.associations.find { _1.from_entity == entity && pattern.match?(_1.qualified_name.to_s) }
      end
    end
  end
end
