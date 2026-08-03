# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

module Mxrb
  module Compiler
    ProjectJarResult = Data.define(:path, :sources, :classes, :classpath_entries)

    # Compiles generated/custom Java sources and writes project.jar without MxBuild or Gradle.
    class ProjectJarBuilder
      LEGACY_UNUSED_IMPORTS = ['com.mendix.webui.CustomJavaAction'].freeze

      def initialize(mpr_path, deployment:, mendix_home:, java_home: nil)
        @mpr_path = File.expand_path(mpr_path)
        @project_root = File.dirname(@mpr_path)
        @deployment = File.expand_path(deployment)
        @mendix_home = File.expand_path(mendix_home)
        @version = SourceModel.read(@mpr_path).version
        @java_major = Runtime::Toolchain.new(@mpr_path).plan.java_version
        @java_home = Runtime::JavaLocator.resolve(@java_major, configured: java_home)
      end

      def build
        validate_java!
        output = File.join(@deployment, 'model', 'bundles', 'project.jar')
        JavaProxyGenerator.new(@mpr_path, project_root: @project_root).generate
        sources = Dir.glob(File.join(@project_root, 'javasource', '**', '*.java')).sort
        classpath = classpath_entries
        compile_and_package(output, sources, classpath)
        result(output, sources, classpath)
      end

      private

      def compile_and_package(output, sources, classpath)
        Dir.mktmpdir('mxrb-java-', @deployment) do |root|
          classes = File.join(root, 'classes')
          FileUtils.mkdir_p(classes)
          compile(stage_legacy_sources(sources, root), classpath, classes, root) unless sources.empty?
          ProjectJarArchive.new(@mpr_path, @project_root, @deployment).write(output, classes)
        end
      end

      def stage_legacy_sources(sources, root)
        sources.map do |source|
          original = File.read(source)
          rendered = strip_legacy_unused_imports(original)
          next source if rendered == original

          relative = source.delete_prefix("#{@project_root}/")
          staged = File.join(root, 'sources', relative)
          FileUtils.mkdir_p(File.dirname(staged))
          File.write(staged, rendered)
          staged
        end
      end

      def strip_legacy_unused_imports(source)
        LEGACY_UNUSED_IMPORTS.reduce(source) do |rendered, class_name|
          simple_name = class_name.split('.').last
          next rendered unless rendered.scan(/\b#{Regexp.escape(simple_name)}\b/).one?

          rendered.gsub(/^import\s+#{Regexp.escape(class_name)};\r?\n/, '')
        end
      end

      def result(output, sources, classpath)
        ProjectJarResult.new(
          path: output, sources: sources.length, classes: jar_classes(output),
          classpath_entries: classpath.length
        )
      end

      def validate_java!
        executable = @java_home && File.join(@java_home, 'bin', 'javac')
        return if executable && File.executable?(executable)

        raise CompilationError, "Java #{@java_major} JDK not found; set MXRB_JAVA_HOME or JAVA_HOME"
      end

      def compile(sources, classpath, classes, root)
        arguments = language_level_arguments + ['-encoding', 'UTF-8', '-d', classes]
        arguments.concat(['-classpath', classpath.join(File::PATH_SEPARATOR)]) unless classpath.empty?
        arguments.concat(sources)
        argument_file = File.join(root, 'javac.args')
        File.write(argument_file, arguments.map { quote_argument(_1) }.join("\n"))
        output, status = Open3.capture2e(File.join(@java_home, 'bin', 'javac'), "@#{argument_file}")
        return if status.success?

        raise CompilationError, "javac failed for #{@mpr_path}:\n#{output}"
      end

      def language_level_arguments
        return ['--release', @java_major] if @java_major.to_i >= 9

        level = "1.#{@java_major}"
        ['-source', level, '-target', level]
      end

      def quote_argument(value)
        %("#{value.to_s.gsub('\\', '\\\\').gsub('"', '\\"')}")
      end

      def classpath_entries
        runtime = File.basename(@mendix_home) == 'runtime' ? @mendix_home : File.join(@mendix_home, 'runtime')
        roots = [
          File.join(runtime, 'bundles'), File.join(@project_root, 'userlib'),
          File.join(@project_root, 'vendorlib'), File.join(@deployment, 'model', 'lib', 'userlib')
        ]
        roots.flat_map { Dir.glob(File.join(_1, '*.jar')) }.uniq.sort
      end

      def jar_classes(path)
        require 'zip'
        Zip::File.open(path) { _1.count { |entry| entry.name.end_with?('.class') } }
      end
    end
  end
end
