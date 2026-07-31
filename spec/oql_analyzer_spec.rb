# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Oql::Analyzer do
  def query(source)
    Mxrb::Oql::Query.new(
      'id', 'Sales.ListOpenOrders', 'ListOpenOrders', :dataset, source, 'unit',
      %w[Source Query], 'DataSets$OqlDataSetSource', [].freeze
    )
  end

  def project_with_query(dir, source)
    path = File.join(dir, 'analyzer.mpr')
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Sales) { entity(:Order) { string :Status } }
    end
    Mxrb.open(path, readonly: false) do |project|
      project.mpr.insert_unit(
        container_uuid: project.modules.first.id,
        containment_name: 'Documents',
        contents_doc: {
          '$Type' => 'DataSets$DataSet', 'Name' => 'ListOpenOrders',
          'Source' => {
            '$Type' => 'DataSets$OqlDataSetSource', 'Query' => source
          }
        }
      )
    end
    path
  end

  def finding(source, rule)
    described_class.new.analyze(query(source)).findings.find { _1.rule == rule }
  end

  it 'flags LIKE with a leading wildcard as an error' do
    result = finding(
      "SELECT o/Status FROM Sales.Order o WHERE o/Status LIKE '%Open'", :like_leading_wildcard
    )
    expect(result).to have_attributes(severity: :error, fragment: "LIKE '%Open'")
    expect(result.suggestions.fetch(:postgresql)).to include('pg_trgm')
  end

  it 'flags LIKE with both wildcards as a warning without duplicating the leading rule' do
    report = described_class.new.analyze(
      query("SELECT o/Status FROM Sales.Order o WHERE o/Status LIKE '%Open%'")
    )
    expect(report.findings.map(&:rule)).to eq([:like_both_wildcard])
    expect(report.findings.first.severity).to eq(:warning)
    expect(report).to be_clean
    expect(report).to be_warnings
  end

  it 'flags trailing-only LIKE as a hint and ignores an exact LIKE' do
    result = finding(
      "SELECT o/Status FROM Sales.Order o WHERE o/Status LIKE 'Open%'", :like_trailing_only
    )
    expect(result.severity).to eq(:hint)
    exact = described_class.new.analyze_source(
      "SELECT o/Status FROM Sales.Order o WHERE o/Status LIKE 'Open'"
    )
    expect(exact.findings).to be_empty
  end

  it 'flags LOWER, UPPER and CAST in WHERE but not in projection' do
    report = described_class.new.analyze_source(
      'SELECT LOWER(o/Status) FROM Sales.Order o ' \
      'WHERE LOWER(o/Status) = \'open\' OR UPPER(o/Status) = \'OPEN\' ' \
      'OR CAST(o/Status AS STRING) = \'Open\' ORDER BY o/Status'
    )
    functions = report.findings.select { _1.rule == :function_in_where }
    expect(functions.map(&:fragment)).to contain_exactly(
      'LOWER(o/Status)', 'UPPER(o/Status)', 'CAST(o/Status AS STRING)'
    )
  end

  it 'flags comma-separated entities without JOIN as a Cartesian join' do
    result = finding(
      'SELECT a/Status FROM Sales.Order a, Sales.Order b WHERE a/Status = b/Status',
      :cartesian_join
    )
    expect(result).to have_attributes(severity: :error)
    expect(result.fragment).to start_with('FROM Sales.Order a, Sales.Order b')

    joined = described_class.new.analyze_source(
      'SELECT a/Status FROM Sales.Order a JOIN Sales.Order b ON a/Status = b/Status, Sales.Order c'
    )
    expect(joined.findings.map(&:rule)).not_to include(:cartesian_join)
  end

  it 'flags SELECT star and alias star but not COUNT star' do
    plain = finding('SELECT * FROM Sales.Order o', :select_star)
    aliased = finding('SELECT o/* FROM Sales.Order o', :select_star)
    aggregate = described_class.new.analyze_source('SELECT COUNT(*) FROM Sales.Order o')
    expect(plain.fragment).to eq('*')
    expect(aliased.fragment).to eq('o/*')
    expect(aggregate.findings).to be_empty
  end

  it 'returns a clean report for a safe query and dialect-specific alternatives' do
    report = described_class.new(dialect: :sql_server).analyze_source(
      'SELECT o/Status FROM Sales.Order o WHERE o/Status = \'Open\''
    )
    expect(report).to be_clean
    expect(report).not_to be_warnings

    warning = described_class.new.analyze_source(
      "SELECT o/Status FROM Sales.Order o WHERE o/Status LIKE '%Open%'"
    )
    alternatives = warning.for_dialect('sql_server')
    expect(alternatives.dig(0, 1)).to include('CONTAINS')
    expect(warning.for_dialect(:ansi).dig(0, 1)).to include('search-specific')
  end

  it 'analyzes SQL ad-hoc and rejects unsupported dialects and languages' do
    report = described_class.new(dialect: :ansi).analyze_sql(
      "SELECT * FROM orders WHERE LOWER(status) LIKE 'Open%'"
    )
    expect(report.query).to have_attributes(kind: :sql, source_type: 'Sql$AdHoc')
    expect(report.findings.map(&:rule)).to include(
      :select_star, :function_in_where, :like_trailing_only
    )
    expect do
      described_class.new(dialect: :oracle)
    end.to raise_error(ArgumentError, /unsupported analysis dialect/)
    expect do
      described_class.new.analyze_source('SELECT 1', language: :graphql)
    end.to raise_error(ArgumentError, /unsupported analysis language/)
  end

  it 'returns project reports for every native OQL query' do
    Dir.mktmpdir do |dir|
      path = project_with_query(
        dir, "SELECT * FROM Sales.Order o WHERE o/Status LIKE '%Open%'"
      )
      reports = Mxrb.open(path) { _1.oql_analysis(dialect: :postgresql) }
      expect(reports).to be_frozen
      expect(reports.one?).to be true
      expect(reports.first.query.qualified_name).to eq('Sales.ListOpenOrders')
      expect(reports.first.findings.map(&:rule)).to contain_exactly(
        :like_both_wildcard, :select_star
      )
    end
  end

  it 'exposes project, OQL, and SQL analysis through text and JSON CLI modes' do
    command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'analyze']
    Dir.mktmpdir do |dir|
      path = project_with_query(
        dir, "SELECT * FROM Sales.Order o WHERE o/Status LIKE '%Open%'"
      )
      stdout, stderr, status = Open3.capture3(*command, path, '--dialect', 'postgresql')
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include(
        'Sales.ListOpenOrders', '[WARNING] like_both_wildcard', 'PostgreSQL ->'
      )
    end

    stdout, stderr, status = Open3.capture3(
      *command, '--sql', 'SELECT * FROM orders', '--dialect', 'sql_server', '--json'
    )
    payload = JSON.parse(stdout)
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(payload.dig(0, 'kind')).to eq('sql')
    expect(payload.dig(0, 'findings', 0, 'selected_suggestion')).to include('Project only')

    stdout, stderr, status = Open3.capture3(
      *command, '--oql', 'SELECT o/Status FROM Sales.Order o'
    )
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('No analysis findings')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
