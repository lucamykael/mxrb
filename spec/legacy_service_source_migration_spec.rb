# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::LegacyServiceSourceMigration do
  def migrate(path, source)
    described_class.new(path:, source:).migrate
  end

  it 'renames legacy flow declarations and execution calls in embedded services' do
    source = <<~RUBY
      module Sales
        class Process < Mxrb::RubyApp::Service
          native :microflow do
            call_microflow 'Sales.Child'
          end

          def call(**arguments)
            native_call(arguments)
          end
        end
      end
    RUBY

    expect(migrate('app/services/sales/process.rb', source)).to eq(
      source.gsub('native :microflow', 'flow :microflow')
            .gsub('native_call(arguments)', 'execute_flow(arguments)')
    )
  end

  it 'supports parenthesized nanoflow declarations' do
    source = "native(:nanoflow) do\nend\n"

    expect(migrate('app/services/sales/client.rb', source)).to eq(
      "flow(:nanoflow) do\nend\n"
    )
  end

  it 'does not rewrite non-service embedded sources' do
    source = "native :microflow\nnative_call(arguments)\n"

    expect(migrate('app/models/sales/order.rb', source)).to equal(source)
  end

  it 'migrates a verified embedded service while restoring it' do
    Dir.mktmpdir('mxrb-legacy-service-') do |dir|
      source = "flow_name = :keep\nnative :microflow\nnative_call(arguments)\n"
      exporter = Mxrb::RubyApp::Exporter.allocate
      exporter.instance_variable_set(:@output_dir, dir)
      files = [{
        path: 'app/services/sales/process.rb', contents: source,
        sha256: Digest::SHA256.hexdigest(source), mode: 0o644
      }]
      exporter.send(:restore_embedded_sources, files)

      expect(File.read(File.join(dir, 'app/services/sales/process.rb'))).to eq(
        "flow_name = :keep\nflow :microflow\nexecute_flow(arguments)\n"
      )
    end
  end
end
# rubocop:enable Metrics/BlockLength
