# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'method-oriented flow branch contracts' do
  def builder
    Mxrb::Dsl::FlowBuilder.new(:Example, runtime: :server, kind: :use_case, public: false)
  end

  def methods_for(source, captions: {})
    Mxrb::Exporter::MethodFlowSource.new(source, captions:).source
  end

  def same_model(source)
    plan = Class.new(Mxrb::Dsl::FlowProgram)
    plan.class_eval(methods_for(source), 'generated_flow.rb', 1)
    generated = builder
    plan.build(generated)
    original = builder
    original.instance_eval(source)
    expect(generated.to_h).to eq(original.to_h)
  end

  it 'refuses invalid Ruby and statements that are not flow declarations' do
    expect { methods_for('decision(') }
      .to raise_error(Mxrb::SerializationError, /invalid Ruby flow definition/)
    expect { methods_for('count = 1') }
      .to raise_error(Mxrb::SerializationError, /non-declaration statement/)
  end

  it 'keeps empty decisions, loops and branches as the same typed model' do
    source = <<~RUBY
      create_object 'App.Item', as: :Item
      decision '$Item = empty' do
      end
      while_loop 'false' do
      end
      type_decision :Item do
        on_type 'App.SpecialItem' do
        end
        otherwise do
          change_variable :Item, to: 'empty'
        end
      end
    RUBY
    methods = methods_for(source)
    expect(methods).to include("decide '$Item = empty', cases: []", 'def while_loop_body', 'def on_type_app_special_item')
    same_model(source)
  end

  it 'keeps callbacks that are already methods and adds one to an empty argument list' do
    methods = methods_for(<<~RUBY)
      while_loop 'false', &handler
      rescue_all() do
        return_value '-1'
      end
    RUBY
    expect(methods).to include("while_loop 'false', &handler", 'rescue_all(&step(:handle_error))')
  end

  it 'names an activity whose caption has no ASCII letters by its position' do
    line = "create_variable :Total, value: '1'"
    methods = methods_for(line, captions: { line => ['合計'] })
    expect(methods).to include('def activity')
  end

  it 'rejects invalid flow plans, steps and decision notations' do
    expect { Mxrb::Dsl::FlowProgram.apply(Object.new, builder) }
      .to raise_error(ArgumentError, 'flow plan must be a class')
    expect { Mxrb::Dsl::FlowProgram.apply(Class.new, builder, entry: :missing) }
      .to raise_error(ArgumentError, 'flow plan has no missing method')
    attempts = {
      'step needs a method or a block, not both' => -> { step(:main_line) { nil } },
      'step needs a method or a block' => -> { step },
      'use one decision branch notation' => -> { decide 'true', branches: {}, if_true: -> {} },
      'decision branches must be a mapping' => -> { decide 'true', branches: [] }
    }
    attempts.each do |message, attempt|
      plan = Class.new(Mxrb::Dsl::FlowProgram) { define_method(:main_line, &attempt) }
      expect { plan.build(builder) }.to raise_error(ArgumentError, message)
    end
  end

  it 'refuses a flow declared with both a plan and a definition block' do
    Dir.mktmpdir('mxrb-flow-plan-') do |directory|
      plan = Class.new(Mxrb::Dsl::FlowProgram) { def main_line = nil }
      expect do
        Mxrb.define(File.join(directory, 'App.mpr')) do
          self.module(:App) { microflow(:Run, plan:) { log_message 'block' } }
        end
      end.to raise_error(ArgumentError, 'use a flow plan or a definition block, not both')
    end
  end

  it 'adds the service entry point to generated source without helper methods' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    expect(exporter.send(:service_method_source, "    def main_line\n    end"))
      .to eq("    def main_line\n    end\n\n    def call(**arguments)\n      execute_flow(arguments)\n    end\n")
  end

  it 'refuses native unit bytes on a read-only model' do
    Dir.mktmpdir('mxrb-readonly-bytes-') do |directory|
      path = File.join(directory, 'App.mpr')
      Mxrb.define(path) { self.module(:App) { entity(:Item) { string :Name } } }
      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      unit = mpr.all_units.first
      expect { mpr.update_unit_bytes(unit.fetch('UnitID'), Mxrb::IO::BsonCodec.serialize({})) }
        .to raise_error(Mxrb::ReadOnlyError)
    ensure
      mpr&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
