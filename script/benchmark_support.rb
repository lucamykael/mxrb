# frozen_string_literal: true

require 'digest'
require 'etc'
require 'json'

# Identity, statistics and explicit performance limits for script/benchmark.
module PipelineBenchmark
  PROTOCOL = 'mxrb-pipeline-v1'
  STAGES = %w[validate semantic_index_cold semantic_index_warm semantic_index_readonly export generate compare].freeze
  METRICS = [*STAGES, 'total'].freeze

  module_function

  def fixture_identity(path)
    { 'name' => File.basename(path), 'sha256' => digest_files(File.dirname(path), fixture_files(path)) }
  end

  def digest_files(root, files)
    digest = Digest::SHA256.new
    files.each do |file|
      relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
      digest << relative << "\0" << Digest::SHA256.file(file).hexdigest << "\0"
    end
    digest.hexdigest
  end

  def asset_identity(path)
    root = File.dirname(path)
    files = Mxrb::Model::DesignSystem::ASSET_DIRECTORIES.flat_map { Dir.glob(File.join(root, _1, '**', '*')) }
    digest_files(root, files.select { File.file?(_1) }.sort)
  end

  def fixture_files(path)
    contents = Dir.glob(File.join(File.dirname(path), 'mprcontents', '**', '*')).select { File.file?(_1) }.sort
    [path, *contents]
  end

  def environment
    cpu = if File.file?('/proc/cpuinfo')
            File.foreach('/proc/cpuinfo').find { _1.start_with?('model name') }&.split(':', 2)&.last&.strip
          end
    { 'ruby_engine' => RUBY_ENGINE, 'ruby_version' => RUBY_VERSION, 'platform' => RUBY_PLATFORM,
      'cpu' => cpu || RbConfig::CONFIG.fetch('host_cpu'), 'processors' => Etc.nprocessors }
  end

  def compatibility(fixture, runs)
    { 'protocol' => PROTOCOL, 'fixture' => fixture_identity(fixture), 'environment' => environment,
      'assets_sha256' => asset_identity(fixture), 'runs' => runs }
  end

  def median(values)
    sorted = values.sort
    middle = sorted.length / 2
    sorted.length.odd? ? sorted.fetch(middle) : (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2.0
  end

  def summarize(samples)
    timings = STAGES.to_h do |stage|
      [stage, median(samples.map { _1.fetch(:measurements_seconds).fetch(stage) }).round(6)]
    end
    { measurements_seconds: timings, total_seconds: median(samples.map { _1.fetch(:total_seconds) }).round(6) }
  end

  # A budget only applies to the exact fixture, protocol, run count and machine class.
  class Budget
    def initialize(data, compatibility)
      raise ArgumentError, 'unsupported budget schema_version' unless data.fetch('schema_version') == 1
      raise ArgumentError, 'incompatible benchmark budget' unless data.fetch('compatibility') == compatibility

      @limits = data.fetch('limits_seconds')
      validate_limits!
    end

    def check(report)
      actual = report.fetch(:measurements_seconds).merge('total' => report.fetch(:total_seconds))
      exceeded = @limits.filter_map do |metric, limit|
        { metric:, actual: actual.fetch(metric), limit: } if actual.fetch(metric) > limit
      end
      { passed: exceeded.empty?, exceeded: }
    end

    private

    def validate_limits!
      unless @limits.is_a?(Hash) && @limits.keys.sort == METRICS.sort
        raise ArgumentError, "budget must define exactly: #{METRICS.join(', ')}"
      end
      return if @limits.values.all? { _1.is_a?(Numeric) && _1.finite? && _1.positive? }

      raise ArgumentError, 'budget limits must be positive finite numbers'
    end
  end
end
