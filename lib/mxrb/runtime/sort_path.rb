# frozen_string_literal: true

require_relative '../io/bson_codec'

module Mxrb
  module Runtime
    # A sort key over an attribute, directly or through associations:
    # "Attr", "Mod.Entity.Attr", "Mod.Assoc/Mod.Target/Attr", or an attribute
    # reference whose entity reference lists the association steps.
    module SortPath
      module_function

      def parse(path, steps: [])
        parts = path.to_s.split('/')
        associations = steps + parts[0..-2].each_slice(2).map(&:first)
        attribute = parts.last.to_s.split('.').last.to_s
        raise ArgumentError, 'sort attribute cannot be empty' if attribute.empty?

        [associations.map(&:to_s).freeze, attribute].freeze
      end

      def from_reference(reference)
        steps = IO::BsonCodec.parse_array(reference.dig('EntityRef', 'Steps'))[:items]
        parse(reference['Attribute'], steps: steps.filter_map { _1['Association'] })
      end

      # Reads each record's value once; associations follow the first related object.
      # The store is resolved only when a key goes through an association.
      def reader(&store)
        cache = {}
        lambda do |record, (associations, attribute)|
          next record.members[attribute] if associations.empty?

          cache.fetch([record.object_id, associations, attribute]) do |key|
            target = associations.reduce(record) do |current, association|
              current && store.call.retrieve_association(association, current).first
            end
            cache[key] = target&.members&.fetch(attribute, nil)
          end
        end
      end
    end
  end
end
