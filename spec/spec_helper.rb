# frozen_string_literal: true

require_relative "coverage_helper"
require "mxrb"

local_environment = Mxrb::Environment.load(root: File.expand_path("..", __dir__))
%w[
  MXRB_FIXTURES_ROOT MXRB_BENCHMARK_MPR MXRB_CONNECTOR_FIXTURE MXRB_ACCEPTANCE_MPRS
].each do |key|
  ENV[key] ||= local_environment[key] if local_environment.key?(key)
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.warnings = true
  config.order = :random
  config.after(:suite) { MxrbCoverage.report } if defined?(MxrbCoverage)
end
