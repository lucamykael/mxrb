# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Application, 'advanced data-grid queries' do
  def record(id, **members)
    Mxrb::Runtime::Native::ObjectValue.new(entity: 'App.Item', id: id.to_s, members:)
  end

  def application(records)
    store = instance_double(Mxrb::Runtime::Native::Store)
    allow(store).to receive(:retrieve).with('App.Item').and_return(records)
    interpreter = double(store:)
    described_class.allocate.tap do |app|
      app.instance_variable_set(:@bridge, double(interpreter:))
    end
  end

  it 'filters, sorts, counts, and paginates records on the server' do
    app = application([
                        record(1, 'Name' => 'Alpha', 'Score' => 5, 'Active' => true,
                                  'CreatedAt' => '2026-01-01', 'Status' => 'New'),
                        record(2, 'Name' => 'Beta', 'Score' => 20, 'Active' => false,
                                  'CreatedAt' => '2026-03-01', 'Status' => 'Done'),
                        record(3, 'Name' => 'Alpine', 'Score' => 15, 'Active' => true,
                                  'CreatedAt' => '2026-02-01', 'Status' => 'New')
                      ])
    page = app.record_page(
      'App.Item',
      filters: [
        { attribute: 'App.Item.Name', type: 'text', operator: 'starts_with', value: 'al' },
        { attribute: 'Score', type: 'number', operator: 'between', value: [5, 15] },
        { attribute: 'Active', type: 'boolean', value: true },
        { attribute: 'CreatedAt', type: 'date', operator: 'on_or_after', value: '2026-01-15' },
        { attribute: 'Status', type: 'enum', value: %w[New Pending] }
      ],
      sort: [{ attribute: 'Score', direction: 'Descending' }], offset: 0, limit: 1
    )

    expect(page).to include(total: 1)
    expect(page.fetch(:records)).to contain_exactly(include(id: '3'))
  end

  it 'implements text, numeric, date, boolean, empty, and comparison operators' do
    app = described_class.allocate
    value = record(1, 'Name' => 'Alphabet', 'Score' => 10, 'CreatedAt' => '2026-02-10',
                      'Active' => false, 'Blank' => nil)
    matches = lambda do |attribute, type, operator, expected = nil|
      app.send(
        :grid_record_matches?, value,
        [{ attribute:, type:, operator:, value: expected }]
      )
    end

    expect(matches.call('Name', 'text', 'contains', 'pha')).to be(true)
    expect(matches.call('Name', 'text', 'ends_with', 'bet')).to be(true)
    expect(matches.call('Name', 'text', 'not_equals', 'Beta')).to be(true)
    expect(matches.call('Score', 'number', 'gt', 9)).to be(true)
    expect(matches.call('Score', 'number', 'gte', 10)).to be(true)
    expect(matches.call('Score', 'number', 'lt', 11)).to be(true)
    expect(matches.call('Score', 'number', 'lte', 10)).to be(true)
    expect(matches.call('CreatedAt', 'date', 'after', '2026-02-01')).to be(true)
    expect(matches.call('CreatedAt', 'date', 'before', '2026-03-01')).to be(true)
    expect(matches.call('CreatedAt', 'date', 'on_or_before', '2026-02-10')).to be(true)
    expect(matches.call('Active', 'boolean', 'not_equals', true)).to be(true)
    expect(matches.call('Blank', 'text', 'empty')).to be(true)
    expect(matches.call('Name', 'text', 'not_empty')).to be(true)
  end

  it 'normalizes typed values and orders nil, numeric, and textual members' do
    app = described_class.allocate
    expect(app.send(:grid_filter_value, 'true', 'boolean')).to be(true)
    expect(app.send(:grid_filter_value, 'false', 'boolean')).to be(false)
    expect(app.send(:grid_filter_value, 'invalid', 'boolean')).to be_nil
    expect(app.send(:grid_filter_value, 'invalid', 'number')).to be_nil
    expect(app.send(:grid_filter_value, 'invalid', 'date')).to be_nil
    expect(app.send(:grid_filter_value, 'value', 'future')).to be_nil
    expect(app.send(:grid_filter_match?, 'invalid', 1, 'number', 'equals')).to be(false)
    expect(app.send(:grid_filter_match?, 1, 'invalid', 'number', 'equals')).to be(false)
    expect(app.send(:grid_filter_match?, 'a', 'a', 'text', 'future')).to be_nil

    expect(app.send(:grid_compare_values, nil, nil)).to eq(0)
    expect(app.send(:grid_compare_values, nil, 'a')).to eq(-1)
    expect(app.send(:grid_compare_values, 'a', nil)).to eq(1)
    expect(app.send(:grid_compare_values, 2, 10)).to eq(-1)
    expect(app.send(:grid_compare_values, 'b', 'a')).to eq(1)
    ordered = app.send(
      :grid_sort_records,
      [record(1, 'Name' => 'Beta'), record(2, 'Name' => 'Alpha')],
      [{ attribute: 'Name' }]
    )
    expect(ordered.map(&:id)).to eq(%w[2 1])
    expect { app.send(:grid_member_name, '') }
      .to raise_error(ArgumentError, /attribute cannot be empty/)
  end

  it 'rejects invalid query types, operators, sorting, and pagination' do
    app = application([record(1, 'Name' => 'Alpha')])
    expect do
      app.record_page('App.Item', filters: [{ attribute: 'Name', type: 'future', value: 'x' }])
    end.to raise_error(ArgumentError, /unsupported filter type/)
    expect do
      app.record_page(
        'App.Item', filters: [{ attribute: 'Name', type: 'text', operator: 'future', value: 'x' }]
      )
    end.to raise_error(ArgumentError, /unsupported text filter operator/)
    expect do
      app.record_page('App.Item', sort: [{ attribute: 'Name', direction: 'Sideways' }])
    end.to raise_error(ArgumentError, /unsupported sort direction/)
    expect { app.record_page('App.Item', offset: -1) }
      .to raise_error(ArgumentError, /offset must be non-negative/)
    expect { app.record_page('App.Item', limit: 0) }
      .to raise_error(ArgumentError, /limit must be positive/)
  end
end
# rubocop:enable Metrics/BlockLength
