# frozen_string_literal: true

require 'json'
require_relative 'catalog'

module Mxrb
  module Studio
    # The parity matrix in both directions. Studio Pro capabilities and their
    # MXRB Ruby APIs/DSL come from a reviewed inventory (parity.json); MXRB
    # operations and the IDE surface that reaches them are derived from the
    # public command catalog and the Studio protocol, so they cannot drift.
    class Parity
      INVENTORY = File.join(__dir__, 'parity.json')

      # Studio protocol methods grouped by the IDE surface that exposes them.
      SURFACES = [
        ['Ruby App Explorer', %w[project/status project/convert project/attach files/list files/create files/move
                                 files/delete files/worktrees files/worktreeAdd files/worktreeRemove]],
        ['Ruby code editor', %w[files/read files/write ruby/syntax ruby/declarations documents/ruby]],
        ['MXRB Tasks', %w[catalog/list catalog/arguments tasks/prepare tasks/run tasks/input tasks/configurations
                          tasks/saveConfiguration tasks/deleteConfiguration sync/preview]],
        ['MXRB Global ER', %w[data/logical]],
        ['MXRB Database', %w[data/connections data/physical data/query data/explain]],
        ['MXRB Parity', %w[parity/matrix]]
      ].freeze

      def initialize(inventory: INVENTORY, catalog: Catalog.new, methods: [])
        @inventory = inventory
        @catalog = catalog
        @methods = methods
      end

      def to_h
        data = JSON.parse(File.read(@inventory))
        @ide_states = data.fetch('ide_surfaces', {}).transform_values { _1.fetch('state') }
        data.merge('mxrb_to_studio_pro' => protocol_rows + catalog_rows)
      end

      private

      def protocol_rows
        exposed = SURFACES.flat_map(&:last)
        rows = SURFACES.flat_map do |surface, methods|
          (methods & @methods).map { protocol_row(_1, surface) }
        end
        rows + (@methods - exposed).map { protocol_row(_1, nil) }
      end

      def protocol_row(method, surface)
        {
          'id' => "studio:#{method}", 'family' => 'studio_protocol', 'capability' => method,
          'mxrb' => ["Mxrb::Studio::Service #{method}"], 'studio_pro' => surface || 'No IDE surface',
          'states' => {
            'ruby_api' => 'implemented_tested_scope',
            'ide' => surface ? @ide_states.fetch(surface, 'implemented_unaccepted') : 'missing',
            'independent_of_studio_backend' => 'yes'
          },
          'gaps' => surface ? [] : ['Not reachable from an IDE surface']
        }
      end

      def catalog_rows
        @catalog.entries.map do |entry|
          {
            'id' => "cli:#{entry[:name]}", 'family' => "cli_#{entry[:context]}", 'capability' => entry[:summary],
            'mxrb' => ["mxrb #{entry[:name]}"], 'studio_pro' => 'MXRB Tasks',
            'states' => { 'ruby_api' => 'source_present_coverage_unassessed', 'ide' => 'task_catalog',
                          'effect' => entry[:effect], 'independent_of_studio_backend' => 'yes' },
            'gaps' => []
          }
        end
      end
    end
  end
end
