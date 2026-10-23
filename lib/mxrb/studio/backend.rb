# frozen_string_literal: true

require 'json'
require 'shellwords'
require 'rbconfig'
require 'open3'
require_relative 'catalog'
require_relative 'files'

module Mxrb
  module Studio
    # Versioned, framework-neutral contract; no dependency on Studio DLLs.
    class Backend # rubocop:disable Metrics/ClassLength
      PROTOCOL_VERSION = 1

      # rubocop:disable Metrics
      def call(request)
        case request.fetch('action')
        when 'catalog' then Catalog.new.entries
        when 'command_arguments'
          Catalog.new.arguments(request.fetch('command_id'), request.fetch('values', {}),
                                extra: Shellwords.split(request.fetch('extra', '')))
        when 'prepare' then arguments(request)
        when 'files' then files(request).list(request.fetch('path', '.'),
                                              include_ignored: request.fetch('include_ignored', false))
        when 'ruby_syntax'
          text = request.fetch('text')
          raise ArgumentError, 'source exceeds 4 MiB' if text.bytesize > Files::MAXIMUM_BYTES

          out, err, status = Open3.capture3(RbConfig.ruby, '-c', stdin_data: text)
          { exit_code: status.exitstatus, output: out, errors: err }
        when 'file_read' then files(request).read(request.fetch('path'))
        when 'file_write'
          files(request).write(request.fetch('path'), text: request.fetch('text'), revision: request.fetch('revision'))
        when 'file_create'
          files(request).create(request.fetch('path'), directory: request.fetch('directory', false),
                                                       text: request.fetch('text', ''))
        when 'file_move' then files(request).move(request.fetch('path'), destination: request.fetch('destination'))
        when 'worktrees' then files(request).worktrees
        when 'snapshot'
          require_relative '../../mxrb'
          require_relative 'snapshot'
          Snapshot.new(request.fetch('model'), destination_root: request.fetch('destination_root')).create
        when 'ruby_project_status', 'ruby_project_convert', 'ruby_project_attach'
          require_relative '../../mxrb'
          require_relative 'ruby_project'
          project = RubyProject.new(request.fetch('source_model'), state_root: request.fetch('state_root'))
          case request['action']
          when 'ruby_project_status' then project.status
          when 'ruby_project_convert' then project.convert(model: request['model'])
          when 'ruby_project_attach' then project.attach(root: request.fetch('root'))
          end
        when 'model_capabilities', 'model_revision', 'model_preview', 'model_apply'
          require_relative '../../mxrb'
          require_relative 'model_operations'
          operations = ModelOperations.new(request.fetch('model'), workspace_root: request.fetch('workspace_root'),
                                                                   source_model: request['source_model'])
          case request['action']
          when 'model_capabilities', 'model_revision'
            operations.public_send(request['action'].delete_prefix('model_'))
          when 'model_preview', 'model_apply'
            operations.public_send(request['action'].delete_prefix('model_'), request.fetch('operation'),
                                   revision: request.fetch('revision'))
          end
        when 'documents', 'document_read', 'document_patch'
          require_relative '../../mxrb'
          require_relative 'documents'
          documents = Documents.new(request.fetch('model'))
          case request['action']
          when 'documents' then documents.list
          when 'document_read' then documents.read(request.fetch('unit_id'))
          when 'document_patch'
            documents.patch(request.fetch('unit_id'), revision: request.fetch('revision'),
                                                      changes: request.fetch('changes'))
          end
        when 'model_catalog', 'domain_diagram'
          require_relative '../../mxrb'
          if request['action'] == 'model_catalog'
            Modeler::Catalog.new(request.fetch('model')).to_h
          else
            DomainDiagram::Document.new(request.fetch('model'), modules: request.fetch('modules', [])).to_h
          end
        when 'data_logical', 'data_physical', 'data_query', 'data_explain'
          require_relative '../../mxrb'
          require_relative 'data_explorer'
          explorer = DataExplorer.new(request.fetch('model'), modules: request.fetch('modules', []),
                                                              database_port: request.fetch('database_port', 55_432))
          case request['action']
          when 'data_logical' then explorer.logical
          when 'data_physical' then explorer.physical
          when 'data_query' then explorer.query(request.fetch('payload'))
          when 'data_explain' then explorer.explain(request.fetch('payload'))
          end
        else raise ArgumentError, "unknown Studio action: #{request['action']}"
        end
      end
      # rubocop:enable Metrics

      def arguments(request) # rubocop:disable Metrics
        raw = if request.key?('command_id')
                Catalog.new.arguments(request.fetch('command_id'), request.fetch('values', {}),
                                      extra: Shellwords.split(request.fetch('extra', '')))
              elsif request.key?('arguments')
                request.fetch('arguments')
              else
                Shellwords.split(request.fetch('command'))
              end
        unless raw.is_a?(Array) && !raw.empty? && raw.all? { _1.is_a?(String) && !_1.include?("\0") }
          raise ArgumentError, 'select an MXRB command'
        end

        substitutions = request.fetch('substitutions', {})
        raw.map do |argument|
          value = substitutions.fetch(argument, argument)
          if value.to_s.empty? || value.match?(/\A\{\w+\}\z/)
            raise ArgumentError, "unresolved workspace argument: #{argument}"
          end

          value
        end
      end

      def execute(request)
        root = File.expand_path('../../..', __dir__)
        directory = File.realpath(request.fetch('directory'))
        argv = arguments(request)
        exec({ 'NO_COLOR' => '1', 'TERM' => 'dumb', 'PAGER' => 'cat', 'GIT_PAGER' => 'cat', 'PSQL_PAGER' => 'cat' },
             RbConfig.ruby, File.join(root, 'bin', 'mxrb'), '--no-progress', *argv, chdir: directory)
      end

      private

      def files(request) = Files.new(request.fetch('root'))
    end
  end
end
