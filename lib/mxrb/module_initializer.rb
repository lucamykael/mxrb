# frozen_string_literal: true

module Mxrb
  # Adds an application module to an existing Ruby-first project atomically.
  class ModuleInitializer < Initializer
    Result = Data.define(:root, :files, :project_file)

    def initialize(name)
      super(name, subject: :module)
    end

    def scaffold(into: Dir.pwd)
      prepare(into)
      install
      Result.new(@module_root, module_files, @project_file)
    ensure
      cleanup
    end

    private

    def prepare(into)
      @project_root = File.expand_path(into)
      @project_file = File.join(@project_root, 'project.rb')
      raise ArgumentError, "#{@project_file}: project.rb not found" unless File.file?(@project_file)

      @module_root = File.join(@project_root, 'modules', @module_name)
      abort "#{@module_root}: directory already exists" if File.exist?(@module_root)

      @staging = Dir.mktmpdir(".#{@module_name}.mxrb-module-", @project_root)
      @project_staging = File.join(@project_root, ".project.rb.mxrb-#{Process.pid}")
      write_module_scaffold(@staging)
      stage_project
    end

    def stage_project
      source = File.binread(@project_file)
      File.binwrite(@project_staging, connect_module(source))
      File.chmod(File.stat(@project_file).mode, @project_staging)
    end

    def install
      FileUtils.mkdir_p(File.dirname(@module_root))
      File.rename(@staging, @module_root)
      @module_installed = true
      File.rename(@project_staging, @project_file)
      @completed = true
    end

    def module_files
      relative_module_files.map { File.join(@module_root, _1) }.freeze
    end

    def connect_module(source)
      raise ArgumentError, 'project.rb does not contain Mxrb.define' unless source.include?('Mxrb.define')

      load_line = %(evaluate File.join(__dir__, "modules", "#{@module_name}", "module.rb"))
      raise ArgumentError, "project.rb already loads #{@module_name}" if source.include?(load_line)

      lines = source.lines
      closing = lines.rindex { _1.strip == 'end' }
      raise ArgumentError, 'project.rb does not contain a closing end' unless closing

      indentation = lines.filter_map { |line| line[/\A\s+(?=evaluate File\.join\(__dir__, "modules")/] }.first || '  '
      lines.insert(closing, "#{indentation}#{load_line}\n")
      lines.join
    end

    def cleanup
      FileUtils.rm_rf(@module_root) if @module_installed && !@completed
      FileUtils.rm_rf(@staging) if @staging && File.exist?(@staging)
      FileUtils.rm_f(@project_staging) if @project_staging && File.exist?(@project_staging)
    end
  end
end
