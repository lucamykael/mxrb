# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Dojo widget entity values' do
  let(:page) { Mxrb::Model::Page.allocate }
  let(:writer) { Mxrb::Writer.new('/tmp/unused.mpr', { version: '11.12.1', modules: [] }) }

  def step(association, destination)
    { '$ID' => 'step', '$Type' => 'DomainModels$EntityRefStep', 'Association' => association,
      'DestinationEntity' => destination }
  end

  def path_ref(*steps)
    { '$ID' => 'ref', '$Type' => 'DomainModels$IndirectEntityRef', 'Steps' => [2, *steps] }
  end

  def property(type, value)
    { 'ValueType' => { 'Type' => type }, 'Value' => value }
  end

  it 'projects an entity property as the path the Mendix client passes to the widget' do
    indirect = { 'EntityRef' => path_ref(step('App.Order_Tag', 'App.Tag'), step('App.Tag_Group', 'App.Group')) }
    expect(page.send(:pluggable_value, indirect, { 'Type' => 'Entity' }))
      .to eq('App.Order_Tag/App.Tag/App.Tag_Group/App.Group')
    direct = { 'EntityRef' => { '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => 'App.Tag' } }
    expect(page.send(:pluggable_value, direct, { 'Type' => 'Entity' })).to eq('App.Tag')
    expect(page.send(:pluggable_value, { 'EntityRef' => path_ref }, { 'Type' => 'Entity' })).to be_nil
    # Association properties keep their projection.
    expect(page.send(:pluggable_value, indirect, { 'Type' => 'Association' })).to be_nil
    expect(page.send(:pluggable_value, { 'XPathConstraint' => '[Active]' }, { 'Type' => 'EntityConstraint' }))
      .to eq('[Active]')
    expect(page.send(:pluggable_value, { 'XPathConstraint' => '' }, { 'Type' => 'EntityConstraint' })).to be_nil
  end

  it 'writes entity paths and constraints back, keeping an unchanged document' do
    original = path_ref(step('App.Order_Tag', 'App.Tag'))
    entity = property('Entity', { 'EntityRef' => original })
    writer.send(:configure_custom_widget_value!, entity, 'App.Order_Tag/App.Tag')
    expect(entity.dig('Value', 'EntityRef')).to be(original)

    writer.send(:configure_custom_widget_value!, entity, 'App.Order_Owner/App.Owner/App.Owner_Group/App.Group')
    reference = entity.dig('Value', 'EntityRef')
    expect(reference['$Type']).to eq('DomainModels$IndirectEntityRef')
    steps = Mxrb::IO::BsonCodec.parse_array(reference['Steps'])[:items]
    expect(steps.map { _1.values_at('Association', 'DestinationEntity') })
      .to eq([%w[App.Order_Owner App.Owner], %w[App.Owner_Group App.Group]])

    writer.send(:configure_custom_widget_value!, entity, 'App.Tag')
    expect(entity.dig('Value', 'EntityRef'))
      .to include('$Type' => 'DomainModels$DirectEntityRef', 'Entity' => 'App.Tag')
    writer.send(:configure_custom_widget_value!, entity, 'App.Tag')
    expect(entity.dig('Value', 'EntityRef', 'Entity')).to eq('App.Tag')
    empty = property('Entity', { 'EntityRef' => nil })
    writer.send(:configure_custom_widget_value!, empty, 'App.Tag')
    expect(empty.dig('Value', 'EntityRef', 'Entity')).to eq('App.Tag')

    constraint = property('EntityConstraint', { 'XPathConstraint' => '' })
    writer.send(:configure_custom_widget_value!, constraint, '[Active = true()]')
    expect(constraint.dig('Value', 'XPathConstraint')).to eq('[Active = true()]')
  end

  it 'reads the property types of Dojo widget packages' do
    types = Mxrb::WidgetPackage::TYPE_MAP.values_at('translatablestring', 'entity', 'entityconstraint',
                                                    'microflow', 'nanoflow', 'form')
    expect(types).to eq(%w[TranslatableString Entity EntityConstraint Microflow Nanoflow Form])
  end
end
# rubocop:enable Metrics/BlockLength
