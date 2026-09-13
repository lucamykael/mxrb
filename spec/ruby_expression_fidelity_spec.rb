# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'native expression source fidelity' do
  let(:exporter) { Mxrb::Exporter.allocate }

  [
    '', 'nil', 'true', 'false', '001', '09', '-001', '1.00', '0.00000000000000000001',
    '12345678901234567890123456789012345678901234567890',
    '$Item/Value', "'quoted text'", "line one\nline two", "\#{raise \"must remain text\"}"
  ].each do |expression|
    it "preserves the exact string #{expression.inspect} as a valid Ruby literal" do
      literal = exporter.send(:ruby_val, expression)
      expect(literal).to eq(expression.inspect)
      expect(Ripper.sexp("value = #{literal}")).not_to be_nil
    end
  end

  it 'retains actual non-string scalar types' do
    [nil, false, true, 0, -7, 1.25, 10**60].each do |value|
      expect(exporter.send(:ruby_val, value)).to eq(value.inspect)
    end
  end

  it 'keeps object mutation expressions exact through the public builder and native writer' do
    values = ['', 'nil', '001', '09', '1.00', '9999999999999999999999999999999999999999']
    members = values.map.with_index { |value, index| { 'Attribute' => "Field#{index}", 'Value' => value } }
    source = exporter.send(:action_dsl_line, { 'Action' => {
      '$Type' => 'Microflows$ChangeObjectAction', 'Variable' => 'Item', 'Members' => [3, *members]
    } }, 0)
    expect(Ripper.sexp(source)).not_to be_nil
    builder = Mxrb::Dsl::FlowBuilder.new(:Change, runtime: :server, kind: :microflow, public: false)
    builder.instance_eval(source, 'native_expression.rb')
    actual = builder.to_h.fetch(:body).first.fetch(:members).map { _1.fetch(:value) }
    expect(actual).to eq(values)
    writer = Mxrb::Writer.new('/tmp/expression-fidelity.mpr', version: '11.12.1', modules: [])
    expect(actual.map { writer.send(:member_value_expr, _1) }).to eq(values)
  end

  it 'exports and recompiles lexical expression variants without changing native flow bytes' do
    expressions = ['001', '09', '1.00', 'nil', '9999999999999999999999999999999999999999']
    Dir.mktmpdir('mxrb-expression-fidelity-') do |directory|
      original = File.join(directory, 'Original.mpr')
      root = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(original) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { string :Value }
          page(:Detail) { title 'Detail' }
          microflow(:PreserveLexicalExpressions) do
            create_object 'App.Item', as: :Item do
              set :Value, to: "'original'"
            end
            expressions.each do |expression|
              change_object(:Item) { set :Value, to: expression }
              show_page('App.Detail', pass: { 'App.Detail.Value' => expression })
            end
          end
        end
      end
      Mxrb::Exporter.new(original, root, mode: :ruby).export!
      source = File.read(Dir.glob(File.join(root, 'app/services/**/*.rb')).first)
      expect(Ripper.sexp(source)).not_to be_nil
      expressions.each do |expression|
        expect(source).to include("to: #{expression.inspect}", "argument \"App.Detail.Value\", #{expression.inspect}")
      end
      Mxrb::RubyApp.compile(root, rebuilt)
      expect(flow_bytes(rebuilt)).to eq(flow_bytes(original))
    end
  end

  def flow_bytes(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    mpr.all_units.filter_map do |unit|
      next unless mpr.parse_contents(unit)['$Type'] == 'Microflows$Microflow'

      [unit.fetch('UnitID'), mpr.content_bytes(unit)]
    end.to_h
  ensure
    mpr&.close
  end
end
# rubocop:enable Metrics/BlockLength
