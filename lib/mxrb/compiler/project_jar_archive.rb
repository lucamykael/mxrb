# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'zip'

module Mxrb
  module Compiler
    # Writes the deterministic OSGi project bundle around compiled Java classes.
    class ProjectJarArchive
      def initialize(mpr_path, project_root, deployment)
        @mpr_path = mpr_path
        @project_root = project_root
        @deployment = deployment
      end

      def write(output, classes)
        FileUtils.mkdir_p(File.dirname(output))
        Dir.mktmpdir('mxrb-project-jar-', File.dirname(output)) do |root|
          temporary = File.join(root, 'project.jar')
          create(temporary, classes)
          FileUtils.mv(temporary, output, force: true)
        end
      end

      private

      def create(path, classes)
        Zip::File.open(path, create: true) do |archive|
          add_string(archive, 'META-INF/MANIFEST.MF', manifest)
          add_tree(archive, classes)
          add_component(archive)
          add_user_resources(archive)
        end
      end

      def add_tree(archive, root)
        Dir.glob(File.join(root, '**', '*')).sort.select { File.file?(_1) }.each do |source|
          add_source(archive, source, source.delete_prefix("#{root}/"))
        end
      end

      def add_component(archive)
        source = File.join(@deployment, 'run', 'component.xml')
        add_source(archive, source, 'OSGI-INF/component.xml') if File.file?(source)
      end

      def add_user_resources(archive)
        root = File.join(@project_root, 'userlib')
        return unless File.directory?(root)

        resources(root).each { add_source(archive, _1, _1.delete_prefix("#{root}/")) }
      end

      def resources(root)
        Dir.glob(File.join(root, '**', '*')).sort.select do |path|
          File.file?(path) && File.extname(path).downcase != '.jar'
        end
      end

      def add_source(archive, source, destination)
        add_string(archive, destination, File.binread(source))
      end

      def add_string(archive, destination, content)
        entry = Zip::Entry.new('', destination)
        entry.time = Packager::FIXED_TIME
        entry.unix_perms = 0o644
        archive.get_output_stream(entry) { _1.write(content) }
      end

      def manifest
        name = File.basename(@mpr_path, File.extname(@mpr_path)).downcase
        <<~MANIFEST.gsub("\n", "\r\n")
          Manifest-Version: 1.0
          Bundle-Name: #{name}
          Bundle-SymbolicName: project
          Service-Component: OSGI-INF/component.xml

        MANIFEST
      end
    end
  end
end
