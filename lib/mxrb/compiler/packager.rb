# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'zip'

module Mxrb
  module Compiler
    PackageResult = Data.define(:path, :mendix_version, :files, :sha256, :metadata)

    # Pure-Ruby MDA container writer. This first compiler stage packages an
    # already materialized deployment and never invokes mx or mxbuild.
    class Packager
      FIXED_TIME = Time.utc(2000, 1, 1).freeze

      def initialize(mpr_path, deployment: nil)
        @mpr_path = File.expand_path(mpr_path)
        @project_root = File.dirname(@mpr_path)
        @deployment = File.expand_path(deployment || File.join(@project_root, 'deployment'))
      end

      def pack(output:, force: false)
        output_path = File.expand_path(output)
        validate_input!(output_path, force:)
        version = Mxrb.open(@mpr_path, &:mendix_version)
        adapter = Adapter.for(version)
        metadata = adapter.validate_deployment!(@deployment)
        files, directories = inventory
        write_atomically(output_path, files, directories)
        package_result(output_path, version, metadata)
      end

      private

      def validate_input!(output, force:)
        raise CompilationError, "#{output}: file already exists" if File.exist?(output) && !force
        return if File.directory?(@deployment)

        raise CompilationError, "#{@deployment}: deployment directory not found"
      end

      def package_result(output, version, metadata)
        inspection = Mda.inspect(output)
        PackageResult.new(
          path: output, mendix_version: version, files: inspection.files.size,
          sha256: inspection.sha256, metadata:
        )
      end

      def inventory
        paths = deployment_paths
        symlink = paths.find { File.symlink?(_1) }
        raise CompilationError, "deployment contains symlink #{symlink}" if symlink

        files = paths.select { File.file?(_1) }.sort_by { relative(_1) }
        directories = paths.select { File.directory?(_1) }.sort_by { relative(_1) }
        [files, directories]
      end

      def deployment_paths
        roots = Adapter::ROOTS.map { File.join(@deployment, _1) }.select { File.exist?(_1) }
        roots.flat_map { Dir.glob(File.join(_1, '**', '*'), File::FNM_DOTMATCH) }
             .concat(roots)
             .reject { %w[. ..].include?(File.basename(_1)) }
      end

      def relative(path)
        path.delete_prefix("#{@deployment}/").tr('\\', '/')
      end

      def write_atomically(output, files, directories)
        FileUtils.mkdir_p(File.dirname(output))
        Dir.mktmpdir('mxrb-mda-', File.dirname(output)) do |tmpdir|
          temporary = File.join(tmpdir, 'package.mda')
          Zip::File.open(temporary, create: true) do |archive|
            directories.each { add_directory(archive, _1) }
            files.each { add_file(archive, _1) }
          end
          FileUtils.mv(temporary, output, force: true)
        end
      end

      def add_directory(archive, source)
        name = "#{relative(source).delete_suffix('/')}/"
        entry = Zip::Entry.new('', name)
        entry.time = FIXED_TIME
        entry.unix_perms = File.stat(source).mode & 0o777
        archive.add(entry, source)
      end

      def add_file(archive, source)
        entry = Zip::Entry.new('', relative(source))
        entry.time = FIXED_TIME
        entry.unix_perms = File.stat(source).mode & 0o777
        archive.add(entry, source)
      end
    end
  end
end
