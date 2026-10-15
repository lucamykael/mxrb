# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Entities and associations named like OQL clauses, such as Shop.Order, are
# qualified names, not clauses.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'OQL names that are clause keywords' do
  around do |example|
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Shop.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Shop do
          entity(:Group) { string :Name }
          entity :Order do
            string :Name
            integer :Limit
            association 'Shop.Group', name: :Order_Group, cardinality: :many_to_one
          end
        end
      end
      @project = Mxrb.open(source)
      @store = Mxrb::Runtime::SQLiteStore.new(@project)
      example.run
    ensure
      @store&.close
      @project&.close
    end
  end

  it 'reads them in FROM, paths and ORDER BY' do
    group = @store.create('Shop.Group').tap { _1.members['Name'] = 'g' }
    @store.commit(group)
    %w[b a].each_with_index do |name, index|
      order = @store.create('Shop.Order')
      order.members.merge!('Name' => name, 'Limit' => index, 'Order_Group' => group)
      @store.commit(order)
    end

    rows = @store.query_oql('SELECT o.Name AS Name, g.Name AS GroupName FROM Shop.Order AS o ' \
                            'JOIN o/Shop.Order_Group/Shop.Group AS g WHERE o.Limit >= 0 ORDER BY Name LIMIT 5')
    expect(rows).to eq([{ 'Name' => 'a', 'GroupName' => 'g' }, { 'Name' => 'b', 'GroupName' => 'g' }])
    expect(@store.query_oql('SELECT COUNT(g.ID) AS Groups FROM Shop.Group g')).to eq([{ 'Groups' => 1 }])
    expect { @store.query_oql('SELECT o.Name AS Name FROM Shop.Order AS o ORDER o.Name') }
      .to raise_error(Mxrb::NativeRuntimeError, /expected ORDER BY/)
  end
end
# rubocop:enable Metrics/BlockLength
