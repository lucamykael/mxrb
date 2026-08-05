# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Audited page patterns that become ordinary editable Mendix pages.
    module PageTemplates
      module_function

      Entry = Data.define(:category, :name, :description, :data_backed)
      ENTRIES = [
        Entry.new('General', 'starter', 'Title and page header', false),
        Entry.new('General', 'blank', 'Empty responsive content area', false),
        Entry.new('Dashboards', 'dashboard', 'Header and three responsive cards', false),
        Entry.new('Forms', 'form-vertical', 'DataView with vertical inputs and actions', true)
      ].freeze

      def fetch(name)
        return unless name

        ENTRIES.find { _1.name == name.to_s } || raise(
          ArgumentError, "page template must be one of: #{ENTRIES.map(&:name).join(', ')}"
        )
      end

      def tree
        groups = ENTRIES.group_by(&:category).to_a
        lines = ['Page templates'] + groups.flat_map.with_index do |group, index|
          category_lines(group, last: index == groups.size - 1)
        end
        lines.join("\n")
      end

      def category_lines(group, last:)
        category, entries = group
        heading = "#{last ? '└──' : '├──'} #{category}"
        children = entries.map.with_index do |entry, index|
          branch = index == entries.size - 1 ? '└──' : '├──'
          "#{last ? '    ' : '│   '}#{branch} #{entry.name} — #{entry.description}"
        end
        [heading, *children]
      end

      def payload
        ENTRIES.group_by(&:category).map do |category, entries|
          {
            category:, templates: entries.map do |entry|
              { name: entry.name, description: entry.description, data_backed: entry.data_backed }
            end
          }
        end
      end
    end
  end
end
