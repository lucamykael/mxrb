# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL view execution' do
  let(:query) do
    'FROM Views.Location SELECT ID AS LocationId, Name AS Name, Amount AS Amount, Active AS Active'
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'Views.mpr')
      expression = query
      Mxrb.define(@source) do
        mendix_version '11.12.1'
        self.module :Views do
          entity :Location do
            string :Name
            decimal :Amount
            boolean :Active
          end
          entity :LocationView do
            string :Name
            decimal :Amount
            boolean :Active
            association 'Views.Location', name: :LocationId, cardinality: :many_to_one
            oql_view query: expression
          end
        end
      end
      @project = Mxrb.open(@source)
      @store = Mxrb::Runtime::SQLiteStore.new(@project)
      example.run
    ensure
      @application&.close
      @store&.close
      @project&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def location(name = 'North')
    @store.create('Views.Location').tap do |record|
      record.members.merge!('Name' => name, 'Amount' => BigDecimal('9007199254740993.125'), 'Active' => true)
    end
  end

  it 'reads only durable values, refreshes after commit and preserves identities and typed projections' do
    source = location
    expect(@store.retrieve('Views.LocationView')).to eq([])
    @store.commit(source)
    view = @store.retrieve('Views.LocationView').first
    expect(view.entity).to eq('Views.LocationView')
    expect(view.id).not_to eq(source.id)
    expect(view.members).to include('Name' => 'North', 'Amount' => BigDecimal('9007199254740993.125'),
                                    'Active' => true, 'LocationId' => source)
    source.members['Name'] = 'Unsaved'
    expect(@store.find('Views.LocationView', view.id).members['Name']).to eq('North')
    expect(@store.find('Views.LocationView', 'missing')).to be_nil
    @store.commit(source)
    updated = @store.retrieve('Views.LocationView').first
    expect(updated.id).to eq(view.id)
    expect(updated.members['Name']).to eq('Unsaved')
    expect(@store.count('Views.LocationView')).to eq(1)
    expect(@store.count('Views.LocationView', ->(value) { value.members['Active'] })).to eq(1)
    expect(@store.retrieve_association('Views.LocationId', updated)).to eq([source])
    expect do
      @store.retrieve_association('Views.LocationId', source)
    end.to raise_error(Mxrb::NativeRuntimeError, /only from/)
    expect { @store.create('Views.LocationView') }.to raise_error(Mxrb::NativeRuntimeError, /read-only/)
    expect { @store.commit([source, view]) }.to raise_error(Mxrb::NativeRuntimeError, /read-only/)
    expect { @store.delete([source, view]) }.to raise_error(Mxrb::NativeRuntimeError, /read-only/)
    expect(@store.count('Views.Location')).to eq(1)
    @store.delete(source)
    expect(@store.find('Views.LocationView', view.id)).to be_nil
  end

  it 'executes from editable Ruby records with MPR access prohibited' do
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
    @application = Mxrb::RubyApp::Application.new(target, process: {})
    @store.close
    @store = @application.send(:bridge).store
    @store.commit(location)
    result = @application.records('Views.LocationView', filters: [{ 'attribute' => 'Name', 'value' => 'North' }])
    expect(result.length).to eq(1)
    expect(result.first[:attributes]).to include('Name' => 'North')
    expect(@application.record('Views.LocationView', result.first[:id])[:attributes]['Amount'])
      .to eq('__mxrb_decimal' => '9007199254740993.125')
    ordinary = @application.send(:bridge).project.modules.find { _1.name == 'Views' }.entities
                           .find { _1.name == 'Location' }
    expect(ordinary.oql_query).to be_nil
    Mxrb::RubyApp::Registry.fetch(:record, 'Views.LocationView').oql_view(source: 'Views.Missing')
    expect { @application.records('Views.LocationView') }
      .to raise_error(Mxrb::NativeRuntimeError, /single-entity projection/)
  end

  it 'rejects a missing native OQL source document' do
    view = @project.modules.find { _1.name == 'Views' }.entities.find { _1.name == 'LocationView' }
    view.source['SourceDocument'] = 'Views.Missing'
    expect { @store.retrieve('Views.LocationView') }
      .to raise_error(Mxrb::NativeRuntimeError, /single-entity projection/)
  end

  context 'with SELECT first and qualified aliases' do
    let(:query) { 'SELECT l.ID AS LocationId, l/Name, l.Amount, l.Active FROM Views.Location AS l' }

    it 'resolves source scope and implicit projection names' do
      @store.commit(location)
      expect(@store.retrieve('Views.LocationView').first.members['Name']).to eq('North')
    end
  end

  {
    'FROM Views.Location SELECT *' => /Unsupported OQL view projection/,
    'FROM Views.Location SELECT x.Name AS Name' => /Unsupported OQL view projection/,
    'DELETE FROM Views.Location' => /single-entity projection/,
    'FROM Views.Location SELECT ID AS LocationId, Name AS Name, Amount AS Amount, Active AS Active; DROP TABLE x' =>
      /Unsupported OQL view projection/,
    'FROM Views.Location SELECT Name AS Name, Name AS Name' => /projections must match/,
    'FROM Views.Location SELECT ID AS LocationId, Missing AS Name, Amount AS Amount, Active AS Active' =>
      /Unknown OQL view source attribute/,
    'FROM Views.Location SELECT Name AS LocationId, Name AS Name, Amount AS Amount, Active AS Active' =>
      /Unsupported OQL view association/
  }.each do |expression, error|
    context "with unsupported query #{expression}" do
      let(:query) { expression }

      it 'fails before executing or silently weakening the query' do
        expect { @store.retrieve('Views.LocationView') }.to raise_error(Mxrb::NativeRuntimeError, error)
        expect(@store.count('Views.Location')).to eq(0)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
