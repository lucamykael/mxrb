# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::NanoflowProgramCompiler do
  def build_source # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir do |root|
      path = File.join(root, 'Nanoflows.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          nanoflow(:Child) { return_value 'true' }
          nanoflow(:Load) do
            create_variable :ready, type: :boolean, value: 'true'
            call_nanoflow 'Demo.Child', as: :child_result
            return_value '$ready'
          end
        end
      end
      yield Mxrb::Compiler::SourceModel.read(path)
    end
  end

  it 'compiles ordered client instructions and nested nanoflow references' do
    build_source do |source|
      compiler = described_class.new(source)
      reference = compiler.reference('Demo.Load')
      output = compiler.declarations

      expect(reference).to match(/\A\(\) => mxrbNanoflow_[a-f0-9]{12}\z/)
      expect(output).to include(
        '"name": "Demo.Load"', '"type": "createVariable"',
        '"type": "nanoflowCall"', '"flow": () => mxrbNanoflow_',
        '"type": "return"', '"variable": "ready"', '"name": "Demo.Child"'
      )
      expect(compiler.reference('Demo.Load')).to eq(reference)
      expect(compiler.unsupported).to be_empty
    end
  end

  it 'fails closed for a missing flow or unsupported client instruction' do
    build_source do |source|
      compiler = described_class.new(source)
      expect(compiler.reference('Demo.Missing')).to be_nil

      flow = source.units_of('Microflows$Nanoflow').find { _1.document['Name'] == 'Load' }
      activity = flow.document.dig('ObjectCollection', 'Objects').find do |item|
        item.is_a?(Hash) && item['$Type'] == 'Microflows$ActionActivity'
      end
      activity['Action']['$Type'] = 'Microflows$UnsupportedClientAction'
      expect(compiler.reference('Demo.Load')).to be_nil
      expect(compiler.unsupported).to include(/UnsupportedClientAction/)
    end
  end

  it 'covers safe instruction and expression variants used by the client schema' do
    build_source do |source|
      compiler = described_class.new(source)
      id = { '$ID' => '11111111-1111-4111-8111-111111111111' }
      expect(compiler.send(:compile_node, '$Type' => 'Microflows$Annotation')).to be_nil
      create = id.merge(
        '$Type' => 'Microflows$ActionActivity',
        'Action' => id.merge('$Type' => 'Microflows$CreateObjectAction',
                             'Entity' => 'Demo.Item', 'VariableName' => 'Item')
      )
      expect(compiler.send(:compile_node, create)).to include(
        type: 'createObject', objectType: 'Demo.Item', outputVar: 'Item'
      )
      call = id.merge(
        '$Type' => 'Microflows$NanoflowCallAction', 'OutputVariableName' => '',
        'NanoflowCall' => { 'Nanoflow' => 'Demo.Child', 'ParameterMappings' => [
          2, nil, { 'Parameter' => 'Demo.Child.Input', 'Argument' => '42' }
        ] }
      )
      expect(compiler.send(:compile_nanoflow_call, call)).to include(
        parameters: [include(name: 'Input', kind: 'primitive')]
      )
      missing = id.merge(
        '$Type' => 'Microflows$NanoflowCallAction',
        'NanoflowCall' => { 'Nanoflow' => 'Demo.Missing' }
      )
      expect(compiler.send(:compile_nanoflow_call, missing)).to be_nil

      expressions = ['', 'empty', '$Item', 'true', 'false', "'text'", '"text"', '-12.5', '@Constant']
      expect(expressions.map { compiler.send(:expression, _1) }).to include(
        { type: 'literal', value: nil }, { type: 'variable', variable: 'Item' },
        { type: 'literal', value: false }, { type: 'literalNumeric', value: '-12.5' },
        { type: 'literal', value: '@Constant' }
      )
      compiler.instance_variable_get(:@programs)['Demo.Nil'] = nil
      expect(compiler.reference('Demo.Nil')).to be_nil
      compiler.send(:unsupported!, { '$Type' => 'Microflows$EmptyAction' }, '')
      expect(compiler.unsupported.last).to end_with(':Microflows$EmptyAction')
    end
  end

  it 'fails closed instead of silently dropping unsupported control flow' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'Branching.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          nanoflow(:Branch) do
            decision '$ready' do
              on(true)  { return_value 'true' }
              on(false) { return_value 'false' }
            end
          end
        end
      end
      compiler = described_class.new(Mxrb::Compiler::SourceModel.read(path))

      expect(compiler.reference('Demo.Branch')).to be_nil
      expect(compiler.declarations).to eq('')
      expect(compiler.unsupported).to include(/Microflows\$ExclusiveSplit/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
