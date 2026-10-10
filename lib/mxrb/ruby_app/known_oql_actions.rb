# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # The two QueryApiBlogPost adapters are enabled only for audited source bytes.
    module KnownOqlActions
      SOURCES = {
        'RetrieveDatasetOql' => %w[
          06695904fdd2fcd853fc2b38adaee17109be04ebdd533a0c4c825464bea4c9ee
          a813210ab1199f915b85100ebc2e853b26e61a609543467dcc973a9f93da7757
        ],
        'RetrieveAdvancedOql' => %w[
          83ff6478fb064eba82bbc5a50d5c50bc311e674806c085f5f6358e66534802f9
          d509cbdccf267c68d5194506ecb379752d5bb9539d3529e8af133c09f49bbe07
        ]
      }.freeze

      module_function

      def registrations(directory)
        SOURCES.filter_map do |name, hashes|
          path = File.join(directory, 'javasource', 'hr', 'actions', "#{name}.java")
          next unless File.file?(path)
          next unless hashes.include?(Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")))

          "Mxrb::RubyApp::KnownOqlActions.register(#{name.inspect})"
        end.join("\n")
      end

      def register(name)
        operation, parameter = {
          'RetrieveDatasetOql' => %i[dataset_objects DataSetName],
          'RetrieveAdvancedOql' => %i[oql_objects OqlQuery]
        }.fetch(name)
        Registry.register_java_custom_action("Hr.#{name}", with_store: true) do |arguments, store:|
          store.public_send(operation, arguments.fetch(parameter.to_s), arguments.fetch('ResultEntity'))
        end
      end
    end
  end
end
