# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio_schema_catalog'

RSpec.describe Mxrb::StudioSchemaCatalog do # rubocop:disable Metrics/BlockLength
  it 'extracts the anchored schema, inheritance, enums, and normalized properties' do # rubocop:disable Metrics/BlockLength
    source = <<~JAVASCRIPT.delete("\n")
      a=x.enum({type:x.schemaType(N,"Mode"),values:["One","Two"]}),
      b=x.element({type:x.schemaType(N,"Widget"),isAbstract:!0,properties:{name:x.string()}}),
      c=b.extend({type:x.schemaType(N,"DataView"),properties:{widgets:x.list(b),mode:a.default("One")}}),
      d=b.extend({type:x.schemaType(N,"Page"),properties:{target:x.byNameReference(()=>z.page).optional()}}),
      q=y.element({type:y.schemaType(Z,"Widget")}),
      r=q.extend({type:y.schemaType(Z,"DataView")}),
      s=q.extend({type:y.schemaType(Z,"Page")})
    JAVASCRIPT

    catalog = described_class.new(
      source, source: '/Studio/main.js', mendix_version: '11.12.1', source_sha256: 'abc123'
    ).extract

    expect(catalog).to include(
      source: '/Studio/main.js', mendix_version: '11.12.1', source_sha256: 'abc123', type_count: 4
    )
    expect(catalog.fetch(:kinds)).to eq('element' => 1, 'enum' => 1, 'extend' => 2)
    expect(catalog.fetch(:widget_types).map { _1.fetch(:name) }).to eq(%w[DataView Page Widget])
    data_view = catalog.dig(:types, 'DataView')
    expect(data_view).to include(base: 'Widget', abstract: false)
    expect(data_view.fetch(:all_properties)).to include(
      include(name: 'name', declared_by: 'Widget', type: 'string'),
      include(name: 'widgets', declared_by: 'DataView', type: 'Widget', cardinality: 'many'),
      include(
        name: 'mode', type: 'Mode', default: true,
        default_value: { kind: 'literal', value: 'One' }
      )
    )
    expect(catalog.dig(:types, 'Page', :properties)).to include(
      include(
        name: 'target', declared_by: 'Page', type: 'by_name', reference: 'by_name', optional: true
      )
    )
  end

  it 'rejects input without the complete page schema anchors' do
    expect { described_class.new('a=x.element({type:x.schemaType(N,"Widget")})').extract }
      .to raise_error(ArgumentError, /Widget, Page, and DataView/)
  end

  it 'extracts files and bridges FormBase to document properties' do
    source = <<~JAVASCRIPT.delete("\n")
      f=y.element({type:y.schemaType(Z,"FormBase"),properties:{own:y.string()}}),
      w=f.extend({type:x.schemaType(N,"Widget"),properties:{}}),
      d=w.extend({type:x.schemaType(N,"DataView"),properties:{}}),
      p=w.extend({type:x.schemaType(N,"Page"),properties:{}})
    JAVASCRIPT
    Dir.mktmpdir('studio-schema-') do |directory|
      path = File.join(directory, 'main.js')
      File.write(path, source)
      catalog = described_class.extract(path, mendix_version: '11.12.1')

      expect(catalog).to include(source: 'main.js', mendix_version: '11.12.1')
      expect(catalog.dig(:types, 'ExportLevel', :values)).to eq(%w[Hidden API])
      expect(catalog.dig(:types, 'FormBase', :properties).map { _1.fetch(:name) })
        .to eq(%w[name documentation excluded exportLevel own])
    end
  end

  it 'decodes every supported default expression and rejects unknown defaults' do
    catalog = described_class.new('')
    values = {
      '!0' => { kind: 'literal', value: true },
      '!1' => { kind: 'literal', value: false },
      '-12' => { kind: 'literal', value: -12 },
      '1e2' => { kind: 'literal', value: 100.0 },
      '{width:10,height:-2}' => { kind: 'size', width: 10, height: -2 },
      'unknownTypeSchema.create()' => { kind: 'unknown_data_type' },
      'widgetSchema.create()' => { kind: 'factory', type: 'Widget' }
    }
    values.each do |expression, expected|
      expect(catalog.send(:default_value, "x.default(#{expression})", 'Widget')).to eq(expected)
    end
    expect { catalog.send(:default_value, 'x.default(future)', 'Widget') }
      .to raise_error(ArgumentError, /unsupported default expression/)
  end

  it 'reports invalid enums and unterminated or escaped schema fragments' do
    invalid_enum = <<~JAVASCRIPT.delete("\n")
      e=x.enum({type:x.schemaType(N,"Mode"),values:[invalid]}),
      w=x.element({type:x.schemaType(N,"Widget")}),
      d=w.extend({type:x.schemaType(N,"DataView")}),
      p=w.extend({type:x.schemaType(N,"Page")})
    JAVASCRIPT
    expect { described_class.new(invalid_enum).extract }
      .to raise_error(ArgumentError, /invalid enum values for Mode/)

    catalog = described_class.new(%q({"escaped\"value"))
    expect(catalog.send(:top_level_indexes, %q("escaped\"value",next), ',')).to eq([16])
    expect { catalog.send(:balanced_fragment, 0, '{', '}') }
      .to raise_error(ArgumentError, /unterminated Studio schema fragment/)
    expect { catalog.send(:balanced_value, %q!("escaped\"value"!, 0, '(', ')') }
      .to raise_error(ArgumentError, /unterminated balanced value/)
  end
end
