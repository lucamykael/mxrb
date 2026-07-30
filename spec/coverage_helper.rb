# frozen_string_literal: true

return unless ENV["MXRB_COVERAGE"] == "1"

require "coverage"
require "fileutils"
require "json"

Coverage.start(lines: true, branches: true)

module MxrbCoverage
  module_function

  # Files requiring Docker, Mendix runtime, or other external infrastructure
  # cannot be covered by unit tests and are excluded from line-coverage enforcement.
  RUNTIME_EXCLUDES = %w[
    mxrb/runtime/executor.rb
    mxrb/runtime/toolchain.rb
    mxrb/runtime/docker_executor.rb
    mxrb/runtime/docker_workspace.rb
  ].freeze

  # Lines annotated with # :nocov: are excluded from branch counting.
  # Inline: `code # :nocov:` → excludes that single line.
  # Block:  a standalone `# :nocov:` comment toggles a region on/off.
  def nocov_lines(path)
    lines = File.readlines(path)
    excluded = Set.new
    in_block = false
    lines.each_with_index do |line, idx|
      lineno = idx + 1
      if line.include?("# :nocov:")
        if line.strip.start_with?("#")
          in_block = !in_block
        else
          excluded.add(lineno)
        end
      elsif in_block
        excluded.add(lineno)
      end
    end
    excluded
  end

  def report
    root = File.expand_path("..", __dir__)
    library = File.join(root, "lib") + "/"
    measured = Coverage.result(stop: false, clear: false).select do |path, _|
      next false unless path.start_with?(library)
      relative = path.delete_prefix(library)
      RUNTIME_EXCLUDES.none? { relative == _1 }
    end
    line_counts = measured.flat_map do |path, coverage|
      excluded = nocov_lines(path)
      coverage.fetch(:lines).each_with_index.filter_map do |count, idx|
        next nil if count.nil? || excluded.include?(idx + 1)
        count
      end
    end
    branch_counts = measured.flat_map do |path, coverage|
      excluded = nocov_lines(path)
      coverage.fetch(:branches).flat_map do |key, hits|
        line = key[2]
        next [] if excluded.include?(line)
        hits.values
      end
    end
    payload = {
      lines: metric(line_counts),
      branches: metric(branch_counts),
      files: measured.to_h do |path, coverage|
        line_data = coverage.fetch(:lines)
        counts = line_data.compact
        details = metric(counts).merge(
          missed_lines: line_data.each_index.select { |index| line_data[index] == 0 }.map { _1 + 1 }
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

    minimum = ENV.fetch("MXRB_COVERAGE_MIN", "100").to_f
    return if payload[:lines][:percent] >= minimum

    raise "line coverage #{payload[:lines][:percent]}% is below #{minimum}%"
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
