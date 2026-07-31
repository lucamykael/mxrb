# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql::SqlServerPlanAnalyzer do
  def showplan(actual: true) # rubocop:disable Metrics/MethodLength
    runtime = if actual
                '<RunTimeInformation><RunTimeCountersPerThread ActualRows="50" ' \
                  'ActualExecutions="2" /></RunTimeInformation>'
              else
                ''
              end
    <<~XML
      <ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan">
        <BatchSequence><Batch><Statements>
          <StmtSimple StatementSubTreeCost="42.5">
            <QueryPlan>
              #{actual ? '<QueryTimeStats ElapsedTime="35.5" />' : ''}
              <MissingIndexes><MissingIndexGroup Impact="88.2">
                <MissingIndex Database="[Shop]" Schema="[dbo]" Table="[Order]">
                  <ColumnGroup Usage="EQUALITY"><Column Name="[Status]" /></ColumnGroup>
                  <ColumnGroup Usage="INCLUDE"><Column Name="[Number]" /></ColumnGroup>
                </MissingIndex>
              </MissingIndexGroup></MissingIndexes>
              <RelOp PhysicalOp="Nested Loops" EstimateRows="20000"
                     EstimatedTotalSubtreeCost="40">
                #{runtime}
                <Warnings><SpillToTempDb /></Warnings>
                <NestedLoops><RelOp PhysicalOp="Table Scan" EstimateRows="5000"
                                    EstimatedTotalSubtreeCost="30">
                  #{runtime}
                  <TableScan><Object Database="[Shop]" Schema="[dbo]" Table="[Order]"
                                     Index="[PK_Order]" /></TableScan>
                </RelOp></NestedLoops>
              </RelOp>
            </QueryPlan>
          </StmtSimple>
        </Statements></Batch></BatchSequence>
      </ShowPlanXML>
    XML
  end

  it 'parses actual operators, spills, misestimates, used indexes and missing-index hints' do
    report = described_class.new.analyze(showplan)

    expect(report).to have_attributes(
      engine: :sql_server, analyzed: true, execution_time_ms: 35.5, total_cost: 42.5
    )
    expect(report).not_to be_clean
    expect(report.findings.map(&:rule)).to include(
      :sql_server_high_volume_nested_loop, :sql_server_tempdb_spill,
      :sql_server_cardinality_misestimation, :sql_server_scan,
      :sql_server_missing_index
    )
    scan = report.findings.find { _1.rule == :sql_server_scan }
    expect(scan).to have_attributes(relation: 'Shop.dbo.Order', node_type: 'Table Scan')
    expect(scan.indexes.first.fetch(:name)).to eq('PK_Order')
    missing = report.findings.find { _1.rule == :sql_server_missing_index }
    expect(missing).to have_attributes(severity: :hint, relation: 'Shop.dbo.Order')
    expect(missing.metrics.fetch(:impact_percent)).to eq(88.2)
    expect(missing.indexes).to include(name: 'Status', usage: 'EQUALITY')
  end

  it 'accepts estimated plans and ignores small index-oriented operators' do
    xml = <<~XML
      <ShowPlanXML><BatchSequence><Batch><Statements>
        <StmtSimple StatementSubTreeCost="0.1"><QueryPlan>
          <RelOp PhysicalOp="Index Seek" EstimateRows="1">
            <IndexScan><Object Schema="[dbo]" Table="[Product]" /></IndexScan>
          </RelOp>
        </QueryPlan></StmtSimple>
      </Statements></Batch></BatchSequence></ShowPlanXML>
    XML
    report = described_class.new.analyze(xml)
    expect(report).to have_attributes(analyzed: false, execution_time_ms: 0.0)
    expect(report.findings).to be_empty
    expect(report).to be_clean
  end

  it 'handles low-volume scans and loops, accurate runtime rows, and incomplete object metadata' do
    xml = <<~XML
      <ShowPlanXML><BatchSequence><Batch><Statements>
        <StmtSimple StatementSubTreeCost="2"><QueryPlan>
          <MissingIndexes><MissingIndexGroup Impact="1" /></MissingIndexes>
          <RelOp PhysicalOp="Table Scan" EstimateRows="5" />
          <RelOp PhysicalOp="Nested Loops" EstimateRows="2" />
          <RelOp PhysicalOp="Hash Match" EstimateRows="100">
            <RunTimeInformation><RunTimeCountersPerThread ActualRows="100" /></RunTimeInformation>
          </RelOp>
          <RelOp PhysicalOp="Table Scan" EstimateRows="2000">
            <TableScan><Object Schema="[dbo]" Table="[NoIndex]" /></TableScan>
          </RelOp>
          <RelOp PhysicalOp="Nested Loops" EstimateRows="20000" />
        </QueryPlan></StmtSimple>
      </Statements></Batch></BatchSequence></ShowPlanXML>
    XML
    report = described_class.new.analyze(xml)
    expect(report.findings.map(&:rule)).to contain_exactly(
      :sql_server_scan, :sql_server_high_volume_nested_loop, :sql_server_missing_index
    )
    expect(report.findings.find { _1.rule == :sql_server_scan }.indexes).to be_empty
    expect(report.findings.find { _1.rule == :sql_server_missing_index }.relation).to be_nil
  end

  it 'rejects malformed or unrelated XML' do
    expect { described_class.new.analyze('') }
      .to raise_error(ArgumentError, /invalid SQL Server SHOWPLAN XML/)
    expect { described_class.new.analyze('<broken>') }
      .to raise_error(ArgumentError, /invalid SQL Server SHOWPLAN XML/)
    expect { described_class.new.analyze('<root/>') }
      .to raise_error(ArgumentError, /invalid SQL Server SHOWPLAN XML/)
  end
end
# rubocop:enable Metrics/BlockLength
