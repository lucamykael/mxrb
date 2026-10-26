# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/structure'
require 'securerandom'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Structure do
  def uuid = SecureRandom.uuid
  def binary(id) = BSON::Binary.new(Mxrb::IO::BsonCodec.uuid_to_blob(id), :generic)

  def element(type, id = uuid, **properties)
    { '$ID' => binary(id), '$Type' => type }.merge(properties.transform_keys(&:to_s))
  end

  def attribute(name, id = uuid, **properties) = element('DomainModels$Attribute', id, Name: name, **properties)

  def entity(name, attributes, id = uuid, **properties)
    element('DomainModels$Entity', id, Name: name, Attributes: [3, *attributes], **properties)
  end

  def domain(entities, id = uuid) = element('DomainModels$DomainModel', id, Entities: [3, *entities])

  describe 'identities' do
    it 'reads binary and textual UUIDs and ignores everything else' do
      id = uuid
      expect(described_class.identity(binary(id))).to eq(id)
      expect(described_class.identity(id.upcase)).to eq(id)
      expect(described_class.identity(BSON::Binary.new('short', :generic))).to be_nil
      expect(described_class.identity('not an id')).to be_nil
      expect(described_class.identity(42)).to be_nil
      expect(described_class.element_list?([3, attribute('A')])).to be(true)
      expect(described_class.element_list?([3, 'text'])).to be(false)
      expect(described_class.element_list?('text')).to be(false)
    end
  end

  describe '.fingerprint' do
    it 'ignores property order, freshly generated IDs and the order of entities' do
      shared = uuid
      left = domain([entity('Order', [attribute('Total')], Location: '0;0'),
                     entity('Customer', [attribute('Name', Ref: binary(shared))])])
      customer = entity('Customer', [attribute('Name', Ref: binary(shared))])
      order = entity('Order', [attribute('Total')], Location: '0;0')
      right = domain([customer, order.to_a.reverse.to_h])
      expect(described_class.fingerprint(left)).to eq(described_class.fingerprint(right))
    end

    it 'keeps the order of ordered lists, external references and every value kind' do
      first = entity('Order', [attribute('A'), attribute('B')])
      swapped = entity('Order', first['Attributes'].values_at(0, 2, 1))
      expect(described_class.fingerprint(first)).not_to eq(described_class.fingerprint(swapped))
      external = ->(target) { element('Forms$Page', Ref: binary(target)) }
      expect(described_class.fingerprint(external.call(uuid)))
        .not_to eq(described_class.fingerprint(external.call(uuid)))
      unnamed = domain([element('DomainModels$Entity', Attributes: [3], Plain: { 'Size' => 1 })])
      expect(described_class.fingerprint(unnamed)).to eq(described_class.fingerprint(domain([element(
        'DomainModels$Entity', Attributes: [3], Plain: { 'Size' => 1 }
      )])))
      values = element('Kinds$Values', Ratio: 1.5, Infinite: Float::INFINITY, Count: 2, Flag: true, Nothing: nil,
                                       When: Time.at(0).utc, Blob: BSON::Binary.new('xy', :generic))
      expect(described_class.canonical(values)).to include(%w[Infinite Infinity], ['Ratio', 1.5],
                                                           ['When', [:value, 'Time', Time.at(0).utc.to_s]],
                                                           ['Blob', [:binary, 'generic', '7879']])
      local = uuid
      text = element('Kinds$Text', local, Self: local)
      expect(described_class.canonical(text, { local => '/x' })).to include(['Self', [:local, '/x']])
    end

    it 'compares values by meaning' do
      expect(described_class.equal?({ 'a' => 1, 'b' => 2 }, { 'b' => 2, 'a' => 1 })).to be(true)
      expect(described_class.equal?([1, 2], [2, 1])).to be(false)
    end
  end

  describe '.index and .ancestors' do
    it 'records each element with its parent element and the property holding it' do
      attr = attribute('Total')
      order = entity('Order', [attr], Extra: { 'Nested' => attribute('Inner') })
      model = domain([order])
      nodes = described_class.index(model)
      expect(nodes.fetch(described_class.id_of(attr)).to_a).to eq([attr, described_class.id_of(order), 'Attributes'])
      inner = order['Extra']['Nested']
      expect(nodes.fetch(described_class.id_of(inner)).key).to eq('Extra')
      expect(described_class.ancestors(nodes, described_class.id_of(attr)))
        .to eq([described_class.id_of(order), described_class.id_of(model)])
    end

    it 'stops at missing parents and cycles' do
      node = described_class::Node
      cyclic = { 'a' => node.new({}, 'b', nil), 'b' => node.new({}, 'a', nil) }
      expect(described_class.ancestors(cyclic, 'a')).to eq(%w[b a])
      expect(described_class.ancestors({ 'a' => node.new({}, 'gone', nil) }, 'a')).to eq(['gone'])
      expect(described_class.ancestors({}, 'missing')).to eq([])
    end
  end

  describe '.reconcile' do
    it 'maps generated IDs onto existing elements by ID, unique name and type order' do
      kept = uuid
      existing_kept = attribute('Kept', kept)
      existing_named = attribute('Named')
      existing_positional = element('DomainModels$ValidationRule')
      existing_duplicate = [attribute('Twin'), attribute('Twin')]
      existing_entity = entity('Order', [existing_kept, existing_named, existing_positional, *existing_duplicate],
                               Settings: { 'Inner' => attribute('Setting') })
      existing = domain([existing_entity])

      generated_entity = entity('Order', [attribute('Kept', kept), attribute('Named'),
                                          element('DomainModels$ValidationRule'), attribute('Twin'),
                                          attribute('Fresh'), element('DomainModels$Index')],
                                Settings: { 'Inner' => attribute('Setting') },
                                Generalization: attribute('Mismatch'))
      generated_entity['Attributes'].insert(2, 'not an element')
      generated_entity['SelfRef'] = generated_entity['$ID']
      generated_entity['TextRef'] = described_class.id_of(generated_entity)
      generated = domain([generated_entity])

      result = described_class.reconcile(generated, existing)
      id = ->(value) { described_class.id_of(value) }
      expect(id.call(result)).to eq(id.call(existing))
      entity = result['Entities'][1]
      expect(id.call(entity)).to eq(id.call(existing_entity))
      expect(entity['SelfRef'].data).to eq(existing_entity['$ID'].data)
      expect(entity['TextRef']).to eq(id.call(existing_entity))
      names = entity['Attributes'].drop(1).grep(Hash).to_h { [_1['Name'] || _1['$Type'], id.call(_1)] }
      expect(names['Kept']).to eq(kept)
      expect(names['Named']).to eq(id.call(existing_named))
      expect(names['DomainModels$ValidationRule']).to eq(id.call(existing_positional))
      expect(names['Twin']).to eq(id.call(existing_duplicate.first))
      expect(existing.values.flatten.grep(Hash).map { id.call(_1) }).not_to include(names['Fresh'])
      expect(id.call(entity['Settings']['Inner'])).to eq(id.call(existing_entity['Settings']['Inner']))
      expect(id.call(entity['Generalization'])).to eq(id.call(generated_entity['Generalization']))
      expect(entity['Attributes'][2]).to eq('not an element')
      expect(generated_entity['SelfRef']).not_to equal(entity['SelfRef'])
    end

    it 'leaves documents of another type unchanged and keeps the identifier representation' do
      generated = element('Forms$Page')
      expect(described_class.reconcile(generated, element('Forms$Snippet'))).to eq(generated)
      text_id = uuid
      existing = { '$ID' => text_id, '$Type' => 'Forms$Page', 'Child' => element('Forms$Widget') }
      generated = element('Forms$Page', Child: element('Forms$Widget'), Count: 3)
      generated['Echo'] = described_class.id_of(generated)
      generated['Back'] = generated['$ID']
      result = described_class.reconcile(generated, existing)
      expect(result['$ID'].data).to eq(Mxrb::IO::BsonCodec.uuid_to_blob(text_id))
      expect(result['Echo']).to eq(text_id)
      expect(result['Count']).to eq(3)
      reversed = described_class.reconcile({ '$ID' => uuid, '$Type' => 'Forms$Page' }, element('Forms$Page', text_id))
      expect(reversed['$ID']).to eq(text_id)
    end
  end

  describe '.diff and .apply' do
    let(:total) { attribute('Total', Length: 10) }
    let(:note) { attribute('Note') }
    let(:order) { entity('Order', [total, note], Documentation: 'old', Child: element('Kind$Child', Value: 1)) }
    let(:before) { domain([order, entity('Customer', [])]) }

    it 'expresses property, list and order changes that apply back onto the original' do
      after = described_class.copy(before)
      changed = after['Entities'][1]
      changed['Documentation'] = 'new'
      changed.delete('Child')
      changed['Added'] = true
      changed['Attributes'][1]['Length'] = 20
      changed['Attributes'] = [3, attribute('Leading'), changed['Attributes'][2], changed['Attributes'][1],
                               attribute('Fresh')]
      after['Entities'] = [3, changed, entity('Product', [])]

      operations = described_class.diff(before, after)
      kinds = operations.map { [_1[:op], _1[:key]] }
      expect(kinds).to include(%w[set Documentation], %w[set Child], %w[set Added], %w[set Length],
                               %w[remove Entities], %w[insert Entities], %w[insert Attributes], %w[order Attributes])
      expect(kinds).not_to include(%w[order Entities])
      applied = described_class.apply(before, operations)
      expect(described_class.fingerprint(applied)).to eq(described_class.fingerprint(after))
      expect(described_class.diff(before, described_class.copy(before))).to eq([])
    end

    it 'inserts at the start, after markers, into new lists and after missing anchors' do
      parent = described_class.id_of(order)
      first = attribute('First')
      created = attribute('Created')
      appended = attribute('Appended')
      operations = [
        { op: 'insert', parent:, key: 'Attributes', element: described_class.id_of(first), value: first,
          after: nil, marker: 3 },
        { op: 'insert', parent:, key: 'Rules', element: described_class.id_of(created), value: created,
          after: nil, marker: nil },
        { op: 'insert', parent:, key: 'Attributes', element: described_class.id_of(appended), value: appended,
          after: uuid, marker: 3 },
        { op: 'insert', parent: uuid, key: 'Attributes', element: uuid, value: attribute('Lost'), after: nil },
        { op: 'remove', parent:, key: 'Missing', element: uuid },
        { op: 'set', element: uuid, key: 'Name', value: 'x', present: true },
        { op: 'order', parent: uuid, key: 'Attributes', order: [] },
        { op: 'order', parent:, key: 'Documentation', order: [] }
      ]
      result = described_class.apply(before, operations)
      list = result['Entities'][1]['Attributes']
      expect(list.first).to eq(3)
      expect(list[1]['Name']).to eq('First')
      expect(list.last['Name']).to eq('Appended')
      expect(result['Entities'][1]['Rules'].map { _1['Name'] }).to eq(['Created'])
      expect(described_class.insert_position([attribute('A')], nil)).to eq(0)
    end
  end

  describe '.conflicts' do
    let(:inner) { attribute('Inner') }
    let(:order) { entity('Order', [inner]) }
    let(:base) { domain([order]) }
    let(:order_id) { described_class.id_of(order) }
    let(:inner_id) { described_class.id_of(inner) }

    def set(element, value, key: 'Name', present: true) = { op: 'set', element:, key:, value:, present: }

    it 'reports the same property set differently, changes inside removed elements and different orders' do
      parent = described_class.id_of(base)
      remove_order = { op: 'remove', parent:, key: 'Entities', element: order_id }
      order_a = { op: 'order', parent: order_id, key: 'Attributes', order: %w[a b] }
      order_b = { op: 'order', parent: order_id, key: 'Attributes', order: %w[b a] }
      ours = [set(inner_id, 'Mine'), order_a, remove_order]
      theirs = [set(inner_id, 'Theirs'), set(parent, 'Mine', key: 'Other'), order_b, remove_order,
                { op: 'insert', parent: order_id, key: 'Attributes', element: 'x' }]
      pairs = described_class.conflicts(base, ours, theirs)
      expect(pairs.map(&:first)).to eq([theirs[0], theirs[2], theirs[3], theirs[4]])
      expect(pairs.first.last).to eq(ours.first)
    end

    it 'accepts identical changes and changes to unrelated elements' do
      expect(described_class.clash?(set(inner_id, 'Same'), set(inner_id, 'Same'), {})).to be(false)
      expect(described_class.clash?(set(inner_id, 'x', present: false), set(inner_id, 'x'), {})).to be(true)
      expect(described_class.clash?(set(inner_id, 'x'), set(order_id, 'y'), {})).to be(false)
      same = { op: 'order', parent: order_id, key: 'Attributes', order: %w[a] }
      expect(described_class.clash?(same, same.dup, {})).to be(false)
      expect(described_class.clash?(same, set(inner_id, 'x'), {})).to be(false)
      removal = { op: 'remove', parent: order_id, key: 'Attributes', element: inner_id }
      other = { op: 'remove', parent: order_id, key: 'Attributes', element: 'other' }
      expect(described_class.clash?(removal, other, described_class.index(base))).to be(false)
      expect(described_class.clash?(removal, removal.dup, described_class.index(base))).to be(false)
      expect(described_class.clash?(set(order_id, 'x'), removal, described_class.index(base))).to be(false)
    end
  end

  describe 'presentation' do
    it 'describes elements by their path of types and names and projects values for JSON' do
      unnamed = element('Forms$LayoutGrid')
      order = entity('Order', [unnamed])
      nodes = described_class.index(domain([order]))
      expect(described_class.describe(nodes, described_class.id_of(unnamed)))
        .to include(type: 'Forms$LayoutGrid', name: nil, path: 'DomainModel / Entity Order / LayoutGrid')
      expect(described_class.describe(nodes, 'missing')).to eq(id: 'missing')
      expect(described_class.label(described_class::Node.new({ 'Name' => '' }, nil, nil))).to eq('')
      id = uuid
      value = { 'a' => [binary(id), BSON::Binary.new('xy', :generic), 1.5, Float::NAN, 'text', 2, nil, Time.at(0).utc] }
      expect(described_class.present(value)).to eq(
        'a' => [id, { binary: '7879' }, 1.5, 'NaN', 'text', 2, nil, Time.at(0).utc.to_s]
      )
      expect(described_class.copy(Time.at(0))).to eq(Time.at(0))
    end
  end
end
# rubocop:enable Metrics
