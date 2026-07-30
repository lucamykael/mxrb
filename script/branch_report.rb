# frozen_string_literal: true

# Lists every uncovered branch per file and line.
# Run: bundle exec ruby script/branch_report.rb

ENV["MXRB_COVERAGE"] = "1"
ENV["MXRB_COVERAGE_MIN"] = "0"

require "rspec/core"

module MxrbCoverage
  module_function

  def branch_report
    root = File.expand_path("..", __dir__)
    library = File.join(root, "lib") + "/"
    measured = Coverage.result(stop: false, clear: false).select do |path, _|
      path.start_with?(library)
    end

    report = Hash.new { |hash, key| hash[key] = [] }
    measured.each do |path, coverage|
      coverage.fetch(:branches).each do |key, hits|
        line = key[2]
        hits.each do |branch_id, count|
          next if count.to_i.positive?

          report[path.delete_prefix(library)] << [line, "#{key[0]} #{key[1]} -> #{branch_id}"]
        end
      end
    end

    report.sort.each do |file, misses|
      puts "\n#{file} (#{misses.size} uncovered)"
      misses.sort.each { |line, desc| puts "  L#{line}: #{desc}" }
    end
    total = report.values.sum(&:size)
    puts "\nTOTAL: #{total} uncovered branches"
  end
end

status = RSpec::Core::Runner.run(["spec"])
MxrbCoverage.branch_report
exit status
