# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Creates conventional Ruby-first artifacts and connects missing aggregators.
    class Generator
      include Recipes

      Result = Data.define(:root, :files, :updated)
      IDENTIFIER = /\A[A-Za-z][A-Za-z0-9_]*\z/

      def initialize(kind, name = nil, target: Dir.pwd)
        @kind = kind.to_sym
        @name = name.to_s
        @root = File.expand_path(target)
        @transaction = Transaction.new
      end

      def scaffold
        send("scaffold_#{@kind}")
        @transaction.commit
        Result.new(@root, @transaction.created.freeze, @transaction.updated.freeze)
      end

      private

      def ensure_presentation(module_name)
        ensure_module(module_name)
        path = module_path(module_name, 'presentation', 'presentation.rb')
        ensure_file(path, Templates.render(:presentation, module_name:, name: nil))
        %w[pages snippets client_actions].each do |directory|
          ensure_file(module_path(module_name, 'presentation', directory, '.keep'), '')
        end
        connect_module_aggregator(module_name, 'presentation', 'presentation.rb')
      end

      def ensure_infrastructure(module_name)
        ensure_module(module_name)
        path = module_path(module_name, 'infrastructure', 'infrastructure.rb')
        ensure_file(path, Templates.render(:infrastructure, module_name:, name: nil))
        connect_module_aggregator(module_name, 'infrastructure', 'infrastructure.rb')
      end

      def ensure_application_directory(module_name, directory)
        ensure_module(module_name)
        ensure_evaluate_dir(module_path(module_name, 'application', 'application.rb'), directory)
      end

      def ensure_evaluate_dir(path, directory)
        source = @transaction.content(path)
        raise ArgumentError, "#{path}: aggregator not found" unless source

        line = %(evaluate_dir File.join(__dir__, "#{directory}"))
        return if source.include?(line)

        @transaction.write(path, "#{source.rstrip}\n#{line}\n")
      end

      def connect_module_aggregator(module_name, *segments)
        path = module_path(module_name, 'module.rb')
        source = @transaction.content(path)
        line = evaluate_line(segments)
        @transaction.write(path, insert_before_closing(source, line, path)) unless source.include?(line)
      end

      def connect_project_file(*segments)
        path = project_path('project.rb')
        source = @transaction.content(path)
        line = evaluate_line(segments)
        @transaction.write(path, insert_before_closing(source, line, path)) unless source.include?(line)
      end

      def insert_before_closing(source, line, path)
        lines = source.lines
        closing = lines.rindex { _1.strip == 'end' }
        raise ArgumentError, "#{path}: closing end not found" unless closing

        indentation = lines.filter_map { _1[/\A\s+(?=evaluate )/] }.first || '  '
        lines.insert(closing, "#{indentation}#{line}\n")
        lines.join
      end

      def create_module_file(module_name, directories, artifact_name, template, suffix: nil)
        ensure_module(module_name)
        filename = "#{Templates.snake_case(artifact_name)}#{suffix}.rb"
        path = module_path(module_name, *directories, filename)
        @transaction.create(path, Templates.render(template, module_name:, name: artifact_name))
      end

      def create_project_file(directories, artifact_name, content)
        path = project_path(*directories, "#{Templates.snake_case(artifact_name)}.rb")
        @transaction.create(path, content)
      end

      def qualified_name
        parts = @name.split('.', 2)
        raise ArgumentError, 'name must be qualified as Module.Artifact' unless parts.size == 2

        [identifier(parts.first, label: 'module'), identifier(parts.last, label: 'artifact')]
      end

      def module_only = identifier(@name, label: 'module')

      def identifier(value, label:)
        raise ArgumentError, "#{label} name must be a Mendix identifier" unless IDENTIFIER.match?(value)

        value
      end

      def ensure_project
        path = project_path('project.rb')
        raise ArgumentError, "#{path}: project.rb not found" unless File.file?(path)
      end

      def ensure_module(module_name)
        ensure_project
        path = module_path(module_name, 'module.rb')
        raise ArgumentError, "#{path}: module not found" unless File.file?(path)
      end

      def project_path(*segments) = File.join(@root, *segments)
      def module_path(module_name, *segments) = project_path('modules', module_name, *segments)

      def evaluate_line(segments)
        quoted = segments.map { |segment| %("#{segment}") }.join(', ')
        "evaluate File.join(__dir__, #{quoted})"
      end
    end
  end
end
