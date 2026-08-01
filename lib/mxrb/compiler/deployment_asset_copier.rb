# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module Compiler
    # Copies project-owned libraries, resources, and compiled theme assets into deployment.
    class DeploymentAssetCopier
      include ModelValues

      SAFE_IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def initialize(project_root, deployment, copier, source: nil)
        @project_root = project_root
        @deployment = deployment
        @copier = copier
        @source = source
      end

      def copy
        %w[userlib vendorlib].each do |name|
          @copier.call(File.join(@project_root, name), File.join(@deployment, 'model', 'lib', 'userlib'))
        end
        copy_root('resources', 'model/resources')
        copy_root('theme/web', 'web')
        copy_root('theme-cache/web', 'web')
        copy_theme_public_assets
        export_images if @source
      end

      private

      def copy_root(source, destination)
        @copier.call(File.join(@project_root, source), File.join(@deployment, destination))
      end

      def copy_theme_public_assets
        pattern = File.join(@project_root, 'themesource', '*', 'public')
        Dir.glob(pattern).sort.each { @copier.call(_1, File.join(@deployment, 'web')) }
      end

      def export_images # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        directory = File.join(@deployment, 'web', 'img')
        FileUtils.mkdir_p(directory)
        @source.units_of('Images$ImageCollection').each do |unit|
          collection = unit.document
          array(collection['Images']).each do |item|
            names = [unit.module_name, collection['Name'], item['Name']]
            unless names.all? { _1.to_s.match?(SAFE_IDENTIFIER) }
              raise CompilationError, "unsafe image identifier #{names.inspect}"
            end

            filename = "#{names.join('$')}.#{image_format(item)}"
            File.binwrite(File.join(directory, filename), image_bytes(item['Image']))
          end
        end
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
  end
end
