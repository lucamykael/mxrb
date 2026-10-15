# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Association paths in microflow expressions' do
  around do |example|
    Dir.mktmpdir('mxrb-expression-paths-') do |root|
      @path = File.join(root, 'Shop.mpr')
      build(@path)
      @project = Mxrb::Model::Project.open(@path)
      example.run
    ensure
      @project&.close
    end
  end

  def build(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Shop do
        entity(:Country) { string :Code }
        entity :Customer do
          string :Name
          association 'Shop.Country', name: :Customer_Country, cardinality: :many_to_one
        end
        entity :Order do
          string :Number
          association 'Shop.Customer', name: :Order_Customer, cardinality: :many_to_one
        end
        entity :Tag do
          string :Label
          association 'Shop.Order', name: :Tag_Order, cardinality: :many_to_many
        end
        microflow :Describe do
          parameter :Order, type: 'Shop.Order'
          return_type :String
          customer = '$Order/Shop.Order_Customer/Shop.Customer'
          create_variable :Text, type: :String,
                                 value: "$Order/Number + ':' + #{customer}/Name + ':' + " \
                                        "#{customer}/Shop.Customer_Country/Shop.Country/Code"
          return_value '$Text'
        end
        microflow :HasCustomer do
          parameter :Order, type: 'Shop.Order'
          return_type :Boolean
          return_value '$Order/Shop.Order_Customer/Shop.Customer != empty and ' \
                       '$Order/Shop.Order_Customer/Shop.Customer/Shop.Customer_Country/Shop.Country/Code = empty'
        end
        microflow :FirstOrder do
          parameter :Customer, type: 'Shop.Customer'
          return_type :String
          return_value '$Customer/Shop.Order_Customer/Shop.Order/Number'
        end
        microflow :Tagged do
          parameter :Tag, type: 'Shop.Tag'
          return_type :String
          return_value '$Tag/Shop.Tag_Order/Shop.Order/Number'
        end
      end
    end
  end

  def seed(store) # rubocop:disable Metrics/AbcSize
    country = store.create('Shop.Country').tap { _1.members['Code'] = 'BR' }
    customer = store.create('Shop.Customer').tap { _1.members.merge!('Name' => 'Ana', 'Customer_Country' => country) }
    order = store.create('Shop.Order').tap { _1.members.merge!('Number' => 'A1', 'Customer_Country' => nil) }
    order.members['Order_Customer'] = customer
    lonely = store.create('Shop.Order').tap { _1.members['Number'] = 'B2' }
    nowhere = store.create('Shop.Customer').tap { _1.members['Name'] = 'Bia' }
    second = store.create('Shop.Order').tap { _1.members.merge!('Number' => 'C3', 'Order_Customer' => nowhere) }
    tag = store.create('Shop.Tag').tap { _1.members.merge!('Label' => 'x', 'Tag_Order' => [order, second]) }
    store.commit([country, customer, order, lonely, nowhere, second, tag])
    { customer:, order:, lonely:, nowhere:, second:, tag: }
  end

  def expect_paths(runtime, records) # rubocop:disable Metrics/AbcSize
    expect(runtime.call('Shop.Describe', 'Order' => records.fetch(:order))).to eq('A1:Ana:BR')
    expect(runtime.call('Shop.HasCustomer', 'Order' => records.fetch(:order))).to be(false)
    expect(runtime.call('Shop.HasCustomer', 'Order' => records.fetch(:second))).to be(true)
    expect(runtime.call('Shop.HasCustomer', 'Order' => records.fetch(:lonely))).to be(false)
    expect(runtime.call('Shop.FirstOrder', 'Customer' => records.fetch(:customer))).to eq('A1')
    expect { runtime.call('Shop.Tagged', 'Tag' => records.fetch(:tag)) }
      .to raise_error(Mxrb::NativeRuntimeError, /cannot follow the reference set Shop\.Tag_Order/)
  end

  it 'follows references both ways in memory' do
    runtime = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect_paths(runtime, seed(runtime.store))
  end

  it 'follows references both ways in SQLite' do
    store = Mxrb::Runtime::SQLiteStore.new(@project)
    runtime = Mxrb::Runtime::Native::Interpreter.new(@project, store:)
    records = seed(store)
    store.release_cache!
    reloaded = records.transform_values { store.find(_1.entity, _1.id) }
    expect_paths(runtime, reloaded)
  ensure
    store&.close
  end

  it 'leaves the other side of a reference empty without an association resolver' do
    expression = Mxrb::Runtime::Native::Expression.new
    customer = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Shop.Customer', id: '1', members: { 'Name' => 'Ana' })
    expect(expression.evaluate('$C/Shop.Order_Customer/Shop.Order/Number', { 'C' => customer })).to be_nil
    expect(expression.evaluate('$C/Shop.Order_Customer', { 'C' => customer })).to be_nil
    expect(expression.evaluate('$C/Name', { 'C' => customer })).to eq('Ana')
    orders = %w[1 2].map { Mxrb::Runtime::Native::ObjectValue.new(entity: 'Shop.Order', id: _1, members: {}) }
    many = Mxrb::Runtime::Native::Expression.new(associations: ->(*) { orders })
    expect(many.evaluate('$C/Shop.Order_Customer', { 'C' => customer })).to eq(orders)
  end
end
# rubocop:enable Metrics/BlockLength

RSpec.describe 'Empty strings in microflow expressions' do
  let(:fixture) { 'spec/fixtures/native_empty_strings' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }

  it 'matches Mendix 11.12.1 with the memory and the SQLite store' do
    Dir.mktmpdir('mxrb-empty-strings-') do |root|
      path = File.join(root, 'Empty.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = path
      load File.join(fixture, 'project.rb')
      project = Mxrb::Model::Project.open(path)
      [nil, Mxrb::Runtime::SQLiteStore.new(project)].each do |store|
        runtime = Mxrb::Runtime::Native::Interpreter.new(project, store:)
        expect(runtime.call('Views.RunAll')).to be(true)
        expect(runtime.log.to_h { _1.delete_prefix('ORACLE ').split('=', 2) }).to eq(expected)
      ensure
        store&.close
      end
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      project&.close
    end
  end
end
