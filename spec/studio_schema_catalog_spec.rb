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
end
