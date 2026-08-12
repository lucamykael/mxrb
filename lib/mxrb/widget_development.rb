# frozen_string_literal: true

require 'fileutils'

module Mxrb
  # Thin, argv-safe integration with Mendix's official TypeScript widget
  # generator and build tool. MXRB consumes the resulting MPK through the
  # existing widget synchronizer instead of inventing a second package format.
  class WidgetDevelopment
    GENERATOR = '@mendix/generator-widget@11.11.0'

    def initialize(runner: nil)
      @runner = runner || lambda do |environment, command, directory|
        system(environment, *command, chdir: directory)
      end
    end

    def create(name, directory: Dir.pwd)
      widget_name = validate_name(name)
      root = File.expand_path(directory)
      FileUtils.mkdir_p(root)
      run!({}, %W[npx --yes #{GENERATOR} #{widget_name}], root)
      File.join(root, widget_name)
    end

    def build(directory, project: nil)
      root = File.expand_path(directory)
      raise ArgumentError, "widget package not found: #{root}" unless File.file?(File.join(root, 'package.json'))

      environment = {}
      environment['MX_PROJECT_PATH'] = File.expand_path(project) if project
      run!(environment, %w[npm ci], root)
      run!(environment, %w[npm run release], root)
      packages = Dir.glob(File.join(root, 'dist', '*.mpk')).sort
      raise CompilationError, "Mendix widget build produced no MPK in #{root}/dist" if packages.empty?

      packages.freeze
    end

    private

    def validate_name(name)
      value = name.to_s.strip
      unless value.match?(/\A[A-Za-z][A-Za-z0-9_-]*\z/)
        raise ArgumentError, 'widget name must start with a letter and contain only letters, digits, _ or -'
      end

      value
    end

    def run!(environment, command, directory)
      return if @runner.call(environment, command, directory)

      raise CompilationError, "command failed: #{command.join(' ')}"
    end
  end
end
