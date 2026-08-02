# frozen_string_literal: true

require 'base64'
require 'rubygems/version'
require 'zlib'

module Mxrb
  module Compiler
    # Versioned Runtime-owned System module omitted from application MPR files.
    class SystemModelSeed
      MODULE_ID = '6e3fe785-0e7d-42ec-a592-8bc1ea4ea87d'
      VERSION_BANDS = [
        ['6.0.0', '7.0.0', '6.10.8'],
        ['7.0.0', '7.17.0', '7.5.0'],
        ['7.17.0', '8.0.0', '7.17.0'],
        ['9.0.0', '10.0.0', '9.6.1.29396'],
        ['11.0.0', '12.0.0', '11.12.1']
      ].map { |minimum, maximum, seed| [Gem::Version.new(minimum), Gem::Version.new(maximum), seed] }
       .freeze

      def self.for(version)
        seed_version = seed_version_for(version)
        path = File.join(__dir__, 'schemas', "system-model-#{seed_version}.b64")
        raise CompilationError, "no native System model seed for Mendix #{version}" unless File.file?(path)

        bytes = Zlib.gunzip(Base64.decode64(File.read(path)))
        new(ModelPackage.decode(bytes, File.basename(path)), target_version: version, seed_version:)
      rescue Zlib::Error, ArgumentError => e
        raise CompilationError, "invalid System model seed for Mendix #{version}: #{e.message}"
      end

      def self.seed_version_for(version) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        exact = version.to_s
        return exact if File.file?(File.join(__dir__, 'schemas', "system-model-#{exact}.b64"))
        unless exact.match?(/\A\d+(?:\.\d+){1,3}(?:[-+].*)?\z/)
          raise CompilationError,
                "invalid Mendix version #{version.inspect}"
        end

        target = Gem::Version.new(exact.scan(/\d+/).first(3).join('.'))
        band = VERSION_BANDS.find { |minimum, maximum, _seed| target >= minimum && target < maximum }
        return band.last if band

        raise CompilationError,
              "no audited native System model seed for Mendix #{version}; " \
              'supported families are 6.x, 7.x, 9.x, and 11.x'
      rescue ArgumentError
        raise CompilationError, "invalid Mendix version #{version.inspect}"
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      attr_reader :package, :target_version, :seed_version

      def initialize(package, target_version: nil, seed_version: nil)
        @package = package
        @target_version = target_version&.to_s
        @seed_version = seed_version&.to_s
      end

      def module_reference
        module_document = package.find(MODULE_ID)&.document
        domain = domain_document
        validate_module!(module_document, domain)

        {
          '$ID' => module_document['$ID'], '$Type' => module_document['$Type'],
          'DomainModel' => domain.slice('$ID', '$Type'),
          'AllDocuments' => document_references(module_document, domain)
        }
      end

      def domain_document
        package.documents.find { _1['$Type'] == 'DomainModels$DomainModel' }
      end

      def document_references(module_document, domain)
        documents = package.documents.reject { [module_document, domain].include?(_1) }
        documents.map { _1.slice('$ID', '$Type') }
      end

      def validate_module!(module_document, domain)
        return if module_document && domain

        raise CompilationError, 'System model seed is missing its module or domain model'
      end
    end
  end
end
