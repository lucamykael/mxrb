# frozen_string_literal: true

module Mxrb
  module Compiler
    # Builds the documents of the Runtime model the way MxBuild writes them: a
    # node carries the fields the version's Runtime schema lists, each given by
    # the compiler, taken from the MPR, or derived when the MPR leaves it out.
    # A compiler including this sets @schema, @page_locations and, to compute
    # fields of its own, overrides `overrides` and `derive`.
    module RuntimeNodes
      include ModelValues

      ZERO_UUID = '00000000-0000-0000-0000-000000000000'

      private

      # A document with the fields the Runtime schema lists: given, taken from
      # the MPR, or derived as MxBuild does; the seed's counterpart fills a field
      # an older MPR lacks.
      def node(source, given = {})
        given = overrides(source).merge(given)
        existing = @schema.counterpart(source) || {}
        @schema.fields_for(source).to_h do |field|
          value = if given.key?(field) then given[field]
                  elsif field == 'TitleOverride' && source['$Type'] == 'Forms$FormSettings' then title_override(source)
                  elsif source.key?(field) then compile_value(source[field])
                  else derived(source, field, existing)
                  end
          [field, value]
        end
      end

      # The fields a compiler computes for a node whatever the MPR holds.
      def overrides(_source) = {}

      # Studio Pro keeps a title override whose template says nothing; MxBuild writes none.
      def title_override(settings)
        template = settings['TitleOverride']
        return compile_value(template) if template.nil? || array(template['Parameters']).any?

        array(template.dig('Text', 'Items')).any? { !_1['Text'].to_s.empty? } ? compile_value(template) : nil
      end

      def compile_value(value)
        case value
        when Hash then value['$Type'] ? node(value) : value.transform_values { compile_value(_1) }
        when Array then array(value).map { compile_value(_1) }
        else value
        end
      end

      # What MxBuild writes for a field the MPR leaves out.
      def derived(source, field, existing)
        return existing[field] if existing.key?(field)

        derive(source, field)
      end

      def derive(source, field)
        if [source['$Type'], field] == ['Forms$FormSettings', 'Location']
          return @page_locations.fetch(source['Form'].to_s, 'Content')
        end

        raise CompilationError, "cannot derive Runtime field #{source['$Type']}.#{field}"
      end
    end
  end
end
