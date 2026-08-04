# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Frontend::Migrator do
  def widget_xml(*properties)
    body = properties.map do |key, type, default|
      default_attribute = default ? %( defaultValue="#{default}") : ''
      %(<property key="#{key}" type="#{type}"#{default_attribute}><caption>#{key}</caption></property>)
    end.join
    <<~XML
      <widget id="example.Widget" supportedPlatform="Web" pluginWidget="true">
        <name>Example</name><properties><propertyGroup caption="General">#{body}</propertyGroup></properties>
      </widget>
    XML
  end

  def package(path, xml)
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream('Widget.xml') { _1.write(xml) }
    end
  end

  def project(dir, version: '11.12.1')
    path = File.join(dir, 'App.mpr')
    Mxrb.define(path) do
      mendix_version version
      self.module(:App) { entity :Item }
    end
    path
  end

  def old_widget(dir, properties)
    old = File.join(dir, 'old.mpk')
    package(old, widget_xml(*properties))
    type, object = Mxrb::WidgetPackage.template(Mxrb::WidgetPackage.new(old).definition('example.Widget'))
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidget',
      'Name' => 'example', 'Type' => type, 'Object' => object
    }
  end

  def insert_document(path, document)
    mpr = Mxrb::IO::MprFile.open(path)
    root = mpr.root_unit.fetch('UnitID')
    mpr.insert_unit(container_uuid: root, containment_name: 'Documents', contents_doc: document)
  ensure
    mpr&.close
  end

  def array(value) = Mxrb::IO::BsonCodec.parse_array(value)[:items]

  it 'previews and applies an installed widget schema update while preserving values by property key' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      FileUtils.mkdir_p(File.join(dir, 'widgets'))
      package(File.join(dir, 'widgets', 'example.mpk'),
              widget_xml(%w[mode enumeration cards], %w[debounce integer 300]))
      widget = old_widget(dir, [%w[mode enumeration list]])
      array(widget.dig('Object', 'Properties')).first['Value']['TextTemplate'] = { 'stale' => true }
      unit_id = insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Home',
        'Widgets' => Mxrb::IO::BsonCodec.build_array([widget])
      })

      plan = described_class.plan(path)
      expect(plan).to be_safe
      expect(plan.widgets).to eq(1)
      expect(plan.layout_rows).to eq(0)
      expect(plan.design_properties).to eq(0)
      expect(plan.changes.map(&:unit_id)).to eq([unit_id])
      plan.apply!
      expect(plan).to be_applied

      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      migrated = array(mpr.parse_contents(mpr.unit(unit_id))['Widgets']).first
      types = array(migrated.dig('Type', 'ObjectType', 'PropertyTypes'))
      values = array(migrated.dig('Object', 'Properties'))
      by_key = types.to_h do |type|
        property = values.find do |candidate|
          Mxrb::IO::BsonCodec.extract_id(candidate['TypePointer']) ==
            Mxrb::IO::BsonCodec.extract_id(type['$ID'])
        end
        [type['PropertyKey'], property.dig('Value', 'PrimitiveValue')]
      end
      expect(by_key).to eq('mode' => 'list', 'debounce' => '300')
      expect(values.first.dig('Value', 'TextTemplate')).to be_nil
      ordered_keys = values.map do |property|
        types.find do |type|
          Mxrb::IO::BsonCodec.extract_id(property['TypePointer']) ==
            Mxrb::IO::BsonCodec.extract_id(type['$ID'])
        end['PropertyKey']
      end
      expect(ordered_keys).to eq(%w[mode debounce])
      mpr.close

      settled = described_class.plan(path)
      expect(settled.changes).to be_empty
      expect(settled).to be_safe
    end
  end

  it 'fails closed when an installed schema removes a used property' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      FileUtils.mkdir_p(File.join(dir, 'widgets'))
      package(File.join(dir, 'widgets', 'example.mpk'), widget_xml(['replacement', 'string', nil]))
      widget = old_widget(dir, [['legacy', 'string', nil]])
      property = array(widget.dig('Object', 'Properties')).first
      property['Value']['PrimitiveValue'] = 'important'
      insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Home', 'Widget' => widget
      })

      plan = described_class.plan(path)
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind)).to include(:removed_configured_widget_property)
      expect { plan.apply! }.to raise_error(Mxrb::SerializationError, /removed_configured_widget_property/)
    end
  end

  it 'losslessly converts boolean widget values to expressions' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      FileUtils.mkdir_p(File.join(dir, 'widgets'))
      package(File.join(dir, 'widgets', 'example.mpk'), widget_xml(%w[required expression false]))
      widget = old_widget(dir, [%w[required boolean false]])
      array(widget.dig('Object', 'Properties')).first['Value']['PrimitiveValue'] = 'true'
      unit_id = insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Home', 'Widget' => widget
      })

      plan = described_class.plan(path)
      expect(plan).to be_safe
      plan.apply!
      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      value = array(mpr.parse_contents(mpr.unit(unit_id)).dig('Widget', 'Object', 'Properties')).first['Value']
      expect(value).to include('Expression' => 'true', 'PrimitiveValue' => '')
      mpr.close
    end
  end

  it 'reconciles a current widget schema whose object still needs model normalization' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      FileUtils.mkdir_p(File.join(dir, 'widgets'))
      properties = [['source', 'datasource', nil]]
      package(File.join(dir, 'widgets', 'example.mpk'), widget_xml(*properties))
      widget = old_widget(dir, properties)
      value = array(widget.dig('Object', 'Properties')).first.fetch('Value')
      value['DataSource'] = {
        '$Type' => 'Forms$MicroflowSettings', 'Microflow' => 'Demo.Source'
      }
      unit_id = insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Home', 'Widget' => widget
      })

      plan = described_class.plan(path)
      expect(plan).to be_safe
      expect(plan.widgets).to eq(1)
      plan.apply!

      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      migrated = mpr.parse_contents(mpr.unit(unit_id)).dig('Widget', 'Object', 'Properties')
      data_source = array(migrated).first.dig('Value', 'DataSource')
      expect(array(data_source['OutputMappings'])).to be_empty
      expect(Mxrb::IO::BsonCodec.parse_array(data_source['OutputMappings'])[:marker]).to eq(3)
      mpr.close
      expect(described_class.plan(path).changes).to be_empty
    end
  end

  it 'blocks missing, ambiguous, and invalid installed widget packages' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      widget = old_widget(dir, [%w[mode enumeration list]])
      insert_document(path, { '$Type' => 'Forms$Page', 'Widget' => widget })
      plan = described_class.plan(path)
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind)).to include(:missing_widget_definition)
    end

    Dir.mktmpdir do |dir|
      path = project(dir)
      widgets = File.join(dir, 'widgets')
      FileUtils.mkdir_p(widgets)
      xml = widget_xml(%w[mode enumeration list])
      package(File.join(widgets, 'a.mpk'), xml)
      package(File.join(widgets, 'b.mpk'), xml)
      insert_document(path, { '$Type' => 'Forms$Page', 'Widget' => old_widget(dir, [%w[mode enumeration list]]) })
      plan = described_class.plan(path)
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind)).to include(:ambiguous_widget_definition)
    end

    Dir.mktmpdir do |dir|
      path = project(dir)
      widgets = File.join(dir, 'widgets')
      FileUtils.mkdir_p(widgets)
      File.binwrite(File.join(widgets, 'broken.mpk'), 'not a zip')
      plan = described_class.plan(path)
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind)).to include(:invalid_widget_package)
    end
  end

  it 'normalizes legacy proportional layout weights without changing their ordering' do
    Dir.mktmpdir do |dir|
      path = project(dir, version: '10.24.0.73019')
      rows = [
        [-1], [-2, -1, -2], [3, -1, -2]
      ].map do |weights|
        {
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$LayoutGridRow',
          'Columns' => Mxrb::IO::BsonCodec.build_array(weights.map do |weight|
            {
              '$ID' => SecureRandom.uuid, '$Type' => 'Forms$LayoutGridColumn',
              'Weight' => weight, 'TabletWeight' => -1, 'PhoneWeight' => -1
            }
          end)
        }
      end
      unit_id = insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Grid', 'Rows' => rows
      })

      plan = described_class.plan(path)
      expect(plan).to be_safe
      expect(plan.layout_rows).to eq(3)
      plan.apply!
      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      migrated = mpr.parse_contents(mpr.unit(unit_id))['Rows']
      expect(migrated.map { |row| array(row['Columns']).map { _1['Weight'] } })
        .to eq([[12], [5, 2, 5], [3, 3, 6]])
      expect(migrated.flat_map { |row| array(row['Columns']) }.map { _1['TabletWeight'] }.uniq)
        .to eq([-1])
      mpr.close
    end
  end

  it 'blocks zero, overcommitted and unsupported layout contracts' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      rows = [[0, -1], [13, -1]].map do |weights|
        {
          '$Type' => 'Forms$LayoutGridRow',
          'Columns' => weights.map do |weight|
            { '$Type' => 'Forms$LayoutGridColumn', 'Weight' => weight,
              'TabletWeight' => weight, 'PhoneWeight' => weight }
          end
        }
      end
      insert_document(path, { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Rows' => rows })
      plan = described_class.plan(path)
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind).uniq).to eq([:unsafe_layout_weights])
    end

    Dir.mktmpdir do |dir|
      plan = described_class.plan(project(dir, version: '9.24.0'))
      expect(plan).not_to be_safe
      expect(plan.issues.map(&:kind)).to eq([:unsupported_version])
    end
  end

  it 'losslessly folds legacy spacing aliases into compound theme properties' do
    Dir.mktmpdir do |dir|
      path = project(dir)
      theme = File.join(dir, 'themesource', 'atlas_core', 'web')
      FileUtils.mkdir_p(theme)
      File.write(File.join(theme, 'design-properties.json'), JSON.pretty_generate(
                                                               'Widget' => [{
                                                                 'name' => 'Spacing', 'type' => 'Spacing',
                                                                 'margin' => [{ 'name' => 'M', 'bottom' => {
                                                                   'oldNames' => ['Spacing bottom::Outer medium']
                                                                 } }]
                                                               }]
                                                             ))
      appearance = {
        'DesignProperties' => Mxrb::IO::BsonCodec.build_array([{
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DesignPropertyValue',
          'Key' => 'Spacing bottom', 'Value' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'Forms$OptionDesignPropertyValue',
            'Option' => 'Outer medium'
          }
        }])
      }
      unit_id = insert_document(path, {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Appearance' => appearance
      })

      plan = described_class.plan(path)
      expect(plan).to be_safe
      expect(plan.design_properties).to eq(1)
      plan.apply!
      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      properties = array(mpr.parse_contents(mpr.unit(unit_id)).dig('Appearance', 'DesignProperties'))
      expect(properties.first['Key']).to eq('Spacing')
      nested = array(properties.first.dig('Value', 'Properties')).first
      expect(nested).to include('Key' => 'margin-bottom', 'Value' => include('Option' => 'M'))
      mpr.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
