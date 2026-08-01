# frozen_string_literal: true

require 'open3'

module Mxrb
  DoctorCheck = Data.define(:name, :status, :message) do
    def ok? = status == :ok
  end
  DoctorReport = Data.define(:root, :checks) do
    def valid? = checks.all? { _1.status != :error }
    def errors = checks.select { _1.status == :error }
    def warnings = checks.select { _1.status == :warning }
  end

  # Diagnoses project structure and optional external toolchain availability.
  class Doctor
    def initialize(root = Dir.pwd, runner: Open3.method(:capture3))
      expanded = File.expand_path(root)
      @root = File.file?(expanded) ? File.dirname(expanded) : expanded
      @runner = runner
    end

    def run
      DoctorReport.new(@root, [
        ruby_check, project_check, modules_check, aggregators_check,
        mpr_check, executable_check('bundle'), executable_check('java'),
        executable_check('docker', warning: true), runtime_check
      ].freeze)
    end

    private

    def ruby_check
      status = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('4.0') ? :ok : :error
      DoctorCheck.new(:ruby, status, "Ruby #{RUBY_VERSION}")
    end

    def project_check = file_check(:project, File.join(@root, 'project.rb'), 'project.rb')

    def modules_check
      modules = Dir[File.join(@root, 'modules', '*', 'module.rb')]
      status = modules.empty? ? :error : :ok
      DoctorCheck.new(:modules, status, "#{modules.size} module definition(s)")
    end

    def aggregators_check
      files = Dir[File.join(@root, 'modules', '**', '*.rb')]
      missing = files.select { File.read(_1).include?('evaluate_dir') }
                     .flat_map { missing_evaluate_dirs(_1) }
      status = missing.empty? ? :ok : :warning
      message = missing.empty? ? 'all referenced directories exist' : missing.join(', ')
      DoctorCheck.new(:aggregators, status, message)
    end

    def missing_evaluate_dirs(path)
      File.read(path).scan(/evaluate_dir File\.join\(__dir__,\s*"([^"]+)"\)/).filter_map do |match|
        directory = File.join(File.dirname(path), match.first)
        directory unless File.directory?(directory)
      end
    end

    def mpr_check
      path = Dir[File.join(@root, '*.mpr')].first
      return DoctorCheck.new(:mpr, :warning, 'no generated MPR found') unless path

      result = Mxrb.validate(path)
      DoctorCheck.new(:mpr, result.valid? ? :ok : :error, "#{result.errors.size} validation error(s)")
    rescue StandardError => e
      DoctorCheck.new(:mpr, :error, e.message)
    end

    def executable_check(name, warning: false)
      available = executable_candidates(name).any? { command_available?(_1) }
      result = available ? :ok : unavailable_status(warning)
      DoctorCheck.new(name.to_sym, result, available ? 'available' : 'not available')
    end

    def command_available?(command)
      _output, _error, status = @runner.call(command, '--version')
      status.success?
    rescue Errno::ENOENT
      false
    end

    def unavailable_status(warning) = warning ? :warning : :error

    def executable_candidates(name)
      return [name] unless name == 'java'

      java_home = ENV['JAVA_HOME'].to_s
      candidates = [java_home.empty? ? nil : File.join(java_home, 'bin', 'java'), name]
      candidates.concat(Dir.glob(File.join(Dir.home, '.asdf', 'installs', 'java', '*', 'bin', 'java')).sort.reverse)
      candidates.compact.uniq
    end

    def runtime_check
      configured = ENV['MXRB_MENDIX_HOME'].to_s
      roots = [configured, File.join(Dir.home, '.local', 'share', 'mendix')].reject(&:empty?)
      candidates = roots.flat_map { runtime_candidates(_1) }.uniq
      found = candidates.find do |root|
        Runtime::RUNTIME_REQUIRED_FILES.all? { File.file?(File.join(root, _1)) }
      end
      DoctorCheck.new(:runtime, found ? :ok : :warning, found || 'not found')
    end

    def runtime_candidates(root)
      direct = File.basename(root) == 'runtime' ? root : File.join(root, 'runtime')
      [direct] + Dir.glob(File.join(root, '*', 'runtime'))
    end

    def file_check(name, path, label)
      DoctorCheck.new(name, File.file?(path) ? :ok : :error,
                      File.file?(path) ? "#{label} found" : "#{label} missing")
    end
  end
end
