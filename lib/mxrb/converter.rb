# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Mxrb
  ConversionResult = Data.define(
    :source, :ruby_root, :mpr, :source_version, :studio_version, :generated_version,
    :source_units, :generated_units, :ruby_artifacts, :source_sha256, :generated_sha256,
    :warnings
  )

  # Converts an existing Mendix app into editable Ruby and materializes an MPR
  # for an explicit Studio Pro version. Export remains the lower-level projection
  # command; convert is the version-bound round-trip entry point.
  class Converter
    VERSION = /\A\d+\.\d+\.\d+(?:\.\d+)?\z/
    AUDITED_CROSS_MAJOR_ROUTES = [
      %w[9.6.1.29396 11.12.1].freeze
    ].freeze

    def self.cross_major_supported?(source_version, target_version)
      AUDITED_CROSS_MAJOR_ROUTES.include?([source_version.to_s, target_version.to_s])
    end

    def initialize(source, ruby_root, studio_version:, output: nil, stack: nil)
      @source = File.expand_path(source)
      @ruby_root = File.expand_path(ruby_root)
      @studio_version = studio_version.to_s
      @output = output && File.expand_path(output)
      @stack = stack&.to_s
    end

    def convert!
      validate_options!
      source_metadata = mpr_metadata(@source)
      validate_conversion_route!(source_metadata.fetch(:version))
      destination = export_ruby
      generated = materialize_mpr(destination)
      integrity = validate_mpr!(generated)
      generated_metadata = mpr_metadata(generated)
      validate_version!(generated_metadata)
      result(source_metadata, destination, generated, generated_metadata, integrity)
    end

    private

    def export_ruby
      destination = Exporter.new(@source, @ruby_root, mode: :ruby).export!
      RubyApp::Preset.apply!(destination, @stack) if @stack
      ProjectLifecycle.new(destination).upgrade(@studio_version, apply: true)
      destination
    end

    def materialize_mpr(destination)
      generated = @output || File.join(destination, 'build', File.basename(@source))
      FileUtils.mkdir_p(File.dirname(generated))
      RubyApp.compile(destination, generated, mendix_version: @studio_version)
      generated
    end

    def validate_mpr!(generated)
      integrity = Mxrb.validate(generated)
      return integrity if integrity.valid?

      raise ValidationError,
            "converted MPR failed integrity validation: #{integrity.errors.join('; ')}"
    end

    def validate_version!(metadata)
      return if metadata.fetch(:version) == @studio_version

      raise ValidationError,
            "converted MPR targets #{metadata.fetch(:version)}, expected #{@studio_version}"
    end

    def validate_conversion_route!(source_version)
      source_major = version_major(source_version, role: 'source MPR')
      target_major = version_major(@studio_version, role: 'target Studio Pro')
      return if source_major == target_major
      return if self.class.cross_major_supported?(source_version, @studio_version)

      routes = AUDITED_CROSS_MAJOR_ROUTES.map { _1.join(' -> ') }.join(', ')
      raise UnsupportedVersion,
            "cross-major conversion #{source_version.inspect} -> #{@studio_version.inspect} " \
            "has no audited metamodel route; available routes: #{routes}"
    end

    def version_major(version, role:)
      value = version.to_s
      return value.split('.').first.to_i if VERSION.match?(value)

      raise UnsupportedVersion, "#{role} has unsupported Mendix version #{version.inspect}"
    end

    def result(source, destination, generated, generated_metadata, integrity)
      ConversionResult.new(
        @source, destination, generated,
        source.fetch(:version), @studio_version, generated_metadata.fetch(:version),
        source.fetch(:units), generated_metadata.fetch(:units),
        RubyApp.application_files(destination).size,
        Digest::SHA256.file(@source).hexdigest, Digest::SHA256.file(generated).hexdigest,
        integrity.warnings.freeze
      )
    end

    def validate_options!
      raise ArgumentError, "MPR not found: #{@source}" unless File.file?(@source)
      unless VERSION.match?(@studio_version)
        raise ArgumentError,
              'Studio Pro version must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH.BUILD'
      end
      return if @stack.nil? || %w[flymetothemoon onrails].include?(@stack)

      raise ArgumentError, "unknown Ruby stack preset #{@stack.inspect}"
    end

    def mpr_metadata(path)
      project = Model::Project.open(path)
      { version: project.mendix_version, units: project.all_units.size }
    ensure
      project&.close
    end
  end
end
