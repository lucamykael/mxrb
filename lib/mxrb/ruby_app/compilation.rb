# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Rebuilds the native project and restores the caller's output environment.
    module Compilation
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
      def compile(root, target = nil, mendix_version: nil)
        previous = ENV['MXRB_OUTPUT_PATH']
        manifest = Manifest.load(root)
        destination = File.expand_path(
          target || ENV.fetch('MXRB_OUTPUT_PATH', File.join(root, 'build', manifest.mpr_name))
        )
        ENV['MXRB_OUTPUT_PATH'] = destination
        runtime_mpr = manifest.absolute_path('runtime_mpr')
        if File.file?(runtime_mpr)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(runtime_mpr, destination)
          runtime_contents = File.join(File.dirname(runtime_mpr), 'mprcontents')
          if File.directory?(runtime_contents)
            FileUtils.cp_r(runtime_contents, File.dirname(destination), remove_destination: true)
          end
          restore_runtime_project(manifest, destination)
        else
          load manifest.absolute_path('mendix_project')
        end
        transitioned = mendix_version && manifest.data.dig('project', 'mendix_version') != mendix_version.to_s
        transition(destination, mendix_version) if mendix_version
        Synchronizer.new(root, destination, manifest:, rebase_member_identities: transitioned).synchronize!
        destination
      ensure
        if previous
          ENV['MXRB_OUTPUT_PATH'] = previous
        else
          ENV.delete('MXRB_OUTPUT_PATH')
        end
      end

      def restore_runtime_project(manifest, destination)
        source = manifest.absolute_path('runtime_project')
        return unless File.directory?(source)

        Dir.children(source).each do |name|
          FileUtils.cp_r(File.join(source, name), File.join(File.dirname(destination), name),
                         remove_destination: true)
        end
      rescue KeyError
        nil
      end

      def transition(path, version)
        project = Model::Project.open(path, readonly: false)
        project.migrate_to!(version) unless project.mendix_version == version.to_s
        # An explicit native target also normalizes legacy storage at the same
        # version. A plain lossless compile retains the source storage format.
        project.mpr.ensure_storage_for_version!(version)
      ensure
        project&.close
      end

      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
    end
  end
end
