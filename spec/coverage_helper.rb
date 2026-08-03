# frozen_string_literal: true

return unless ENV["MXRB_COVERAGE"] == "1"

require "coverage"
require "fileutils"
require "json"

Coverage.start(lines: true, branches: true)

module MxrbCoverage
  module_function

  def report
    root = File.expand_path("..", __dir__)
    library = File.join(root, "lib") + "/"
    measured = Coverage.result(stop: false, clear: false).select do |path, _|
      path.start_with?(library)
    end
    line_counts = measured.flat_map { |_path, coverage| coverage.fetch(:lines).compact }
    branch_counts = measured.flat_map do |_path, coverage|
      coverage.fetch(:branches).flat_map { |_key, hits| hits.values }
    end
    payload = {
      lines: metric(line_counts),
      branches: metric(branch_counts),
      files: measured.to_h do |path, coverage|
        line_data = coverage.fetch(:lines)
        counts = line_data.compact
        details = metric(counts).merge(
          missed_lines: line_data.each_index.select { |index| line_data[index] == 0 }.map { _1 + 1 },
          missed_branches: coverage.fetch(:branches).flat_map do |branch, hits|
            hits.filter_map { |target, count| { branch:, target: } if count.zero? }
          end
        )
        [path.delete_prefix(library), details]
      end
    }
    directory = File.join(root, "coverage")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "coverage.json"), JSON.pretty_generate(payload))

    warn format(
      "MXRB coverage: lines %.2f%% (%d/%d), branches %.2f%% (%d/%d)",
      payload[:lines][:percent], payload[:lines][:covered], payload[:lines][:total],
      payload[:branches][:percent], payload[:branches][:covered], payload[:branches][:total]
    )

    minimums = {
      lines: ENV.fetch("MXRB_LINE_COVERAGE_MIN", ENV.fetch("MXRB_COVERAGE_MIN", "100")).to_f,
      branches: ENV.fetch("MXRB_BRANCH_COVERAGE_MIN", ENV.fetch("MXRB_COVERAGE_MIN", "100")).to_f
    }
    failures = %i[lines branches].filter_map do |metric_name|
      percent = payload.fetch(metric_name).fetch(:percent)
      minimum = minimums.fetch(metric_name)
      "#{metric_name} coverage #{percent}% is below #{minimum}%" if percent < minimum
    end
    return if failures.empty?

    missed = payload[:files].filter_map do |path, details|
      lines = details[:missed_lines]
      "#{path}:#{lines.join(',')}" unless lines.empty?
    end
    raise [failures.join("; "), "missed lines: #{missed.join('; ')}"].join("; ")
  end

  def metric(counts)
    total = counts.size
    covered = counts.count { _1.to_i.positive? }
    {
      covered: covered,
      total: total,
      percent: total.zero? ? 100.0 : (covered * 100.0 / total).round(2)
    }
  end
end
