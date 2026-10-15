# frozen_string_literal: true

require_relative 'oql_datasets'
require_relative 'java_action_context'

module Mxrb
  module Runtime
    # ExecuteOQLStatement and CountRowsOQLStatement of the Marketplace OQL module:
    # OQL text (and, since 3.x, a dataset name) with $parameters, an amount and an
    # offset. Each column fills an attribute of the same name or, for object IDs, an
    # owned association named Module.Column; unknown columns fail as in the module.
    class OqlModuleQuery
      RESERVED = /\A(.+\.ID|submetaobjectname)\z/
      # 2.x maps every column, throws NullPointerException and matches associations
      # by their unqualified name only.
      LEGACY = '2.10.0'

      def initialize(datasets, store, release: '4.1.2')
        @datasets = datasets
        @store = store
        @legacy = release == LEGACY
      end

      def objects(statement, entity_name, parameters:, amount: nil, offset: nil)
        attributes = @datasets.entity(entity_name).attributes.map(&:name)
        text = @legacy ? statement : @datasets.dataset_text(statement) || statement
        table = @datasets.query(text, parameters:)
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
            next if !@legacy && RESERVED.match?(column)

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

        message = if !value.nil? then "Could not find result attribute #{column} in target object."
                  elsif @legacy then "Null value found #{column} was not found as association or attribute."
                  else "Unable to map null value for column #{column} to any association or attribute."
                  end
        module_error(message)
      end

      def link(object, column, id)
        association = association(object.entity, column)
        module_error("Could not find result association #{column} in target object.") unless association

        object.members[association.name] = @store.find(association.to_entity, id)
      end

      def association(entity, column)
        @store.schema.associations.find do |candidate|
          name = candidate.qualified_name.to_s
          next false unless candidate.from_entity == entity

          @legacy || !column.include?('.') ? name.split('.', 2).last == column : name == column
        end
      end

      def module_error(message)
        raise JavaActionError.new(@legacy ? 'java.lang.NullPointerException' : 'java.lang.RuntimeException', message)
      end
    end
  end
end
