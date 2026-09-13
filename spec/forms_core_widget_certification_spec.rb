# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'
require 'mxrb/forms/certification'

RSpec.describe 'Mendix 11.12.1 core Forms widget certification' do # rubocop:disable Metrics/BlockLength
  def sample_values(property, catalog)
    Mxrb::Forms::Certification.sample_values(property, catalog:)
  end

  def signature(value)
    Mxrb::Forms::Certification.signature(value)
  end

  def opaque_source?(source)
    Mxrb::Forms::Certification.opaque_source?(source)
  end

  def certify(widget, property, value, environment) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    catalog, emitter, codec = environment
    node = Mxrb::Forms::Node.new(widget.name, catalog:)
    node.set(property.name, value)
    source = emitter.emit(node)
    expected = signature(node)
    failures = []
    failures << 'opaque Ruby source' if opaque_source?(source)
    failures << 'Ruby source changed semantics' if signature(eval(source)) != expected # rubocop:disable Security/Eval
    failures << 'storage changed semantics' if signature(codec.decode(codec.encode(node))) != expected
    [[widget.name, property.name], failures.map { "#{widget.name}.#{property.name} (#{value.inspect}): #{_1}" }]
  rescue StandardError, ScriptError => e
    [[widget.name, property.name], ["#{widget.name}.#{property.name} (#{value.inspect}): #{e.class}: #{e.message}"]]
  end

  it 'losslessly certifies every inherited property occurrence through clean Ruby and typed storage' do
    catalog = Mxrb::Forms::Catalog.for('11.12.1')
    emitter = Mxrb::Forms::SourceEmitter.new
    codec = Mxrb::Forms::MprCodec.new(
      reference_decoder: ->(value, _path) { value.to_s },
      reference_encoder: ->(target, _path) { target.to_s }
    )
    environment = [catalog, emitter, codec]
    results = catalog.concrete_widgets.flat_map do |widget|
      widget.all_properties.flat_map do |property|
        sample_values(property, catalog).map do |value|
          certify(widget, property, value, environment)
        end
      end
    end
    certified = results.map(&:first)
    failures = results.flat_map(&:last)

    expect(certified.map(&:first).uniq.size).to eq(41)
    expect(certified.size).to eq(825)
    expect(certified.uniq.size).to eq(455)
    expect(failures).to be_empty, -> { failures.join("\n") }
  end
end
