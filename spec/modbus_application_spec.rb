# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../examples/modbus_application'

RSpec.describe Mxrb::Modbus::ApplicationDemo do # rubocop:disable Metrics/BlockLength
  it 'writes and reads through a microflow and persists both samples across a database reopen' do
    Dir.mktmpdir('modbus-application-spec-') do |root|
      result = described_class.run(root)
      expect(result).to include(transport: :tcp, model_valid: true)
      expect(result.fetch(:persisted_measurements)).to eq([
                                                            { setpoint: 42, input_value: 1234 },
                                                            { setpoint: 84, input_value: 1234 }
                                                          ])
      expect(File).to exist(result.fetch(:mpr))
      expect(File).to exist(result.fetch(:database))
      expect { described_class.run(root) }.to raise_error(ArgumentError, /already exists/)
    end
  end

  it 'keeps generated demo files isolated from a caller output-path override' do
    previous = ENV['MXRB_OUTPUT_PATH']
    Dir.mktmpdir('modbus-output-spec-') do |root|
      protected_path = File.join(root, 'existing.mpr')
      File.write(protected_path, 'preserve existing project')
      ENV['MXRB_OUTPUT_PATH'] = protected_path
      path = File.join(root, 'demo.mpr')
      described_class.build_project(path)
      expect(Mxrb.validate(path)).to be_valid
      expect(File.read(protected_path)).to eq('preserve existing project')
    end
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
