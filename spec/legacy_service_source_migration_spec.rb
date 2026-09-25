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

  it 'migrates explicit self receivers while ignoring singleton APIs' do
    source = <<~RUBY
      class Process < Mxrb::RubyApp::Service
        self.native :microflow do
        end
        self.native(:nanoflow) do
        end

        def call(arguments)
          self.native_call(arguments)
        end

        class << self
          def native_call(arguments) = arguments
        end

        def self.native_call(arguments) = arguments
      end
    RUBY
    migrated = migrate('app/services/process.rb', source)

    expect(migrated).to include('self.flow :microflow', 'self.flow(:nanoflow)', 'self.execute_flow(arguments)')
    expect(migrated.scan('def native_call').size).to eq(1)
    expect(migrated).to include('def self.native_call')
  end

  it 'does not infer service semantics from unrelated call and constant shapes' do
    source = <<~RUBY
      class Local < Service
        other.native(:microflow)
      end
      class Dynamic < service_class
        native :microflow
      end
      class Absolute < ::Mxrb::RubyApp::Service
        native :microflow
      end
    RUBY

    migrated = migrate('app/services/shapes.rb', source)
    expect(migrated).to include('class Local < Service', 'other.native(:microflow)',
                                'class Dynamic < service_class', 'native :microflow',
                                'class Absolute < ::Mxrb::RubyApp::Service', 'flow :microflow')
    migration = described_class.new(path: 'app/services/shapes.rb', source: '')
    expect(migration.send(:call_identifier, [:call, [:vcall, [:@ident, 'other']], :'.', [:@ident, 'native']]))
      .to be_nil
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

  it 'keeps regenerated public projections instead of restoring generated legacy identities' do
    Dir.mktmpdir('mxrb-legacy-public-projection-') do |dir|
      exporter = Mxrb::RubyApp::Exporter.allocate
      exporter.instance_variable_set(:@output_dir, dir)
      relative = 'app/constants/app/environment.rb'
      generated = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(generated))
      File.write(generated, "mendix_name \"App.Environment\"\n")
      legacy = "mendix_name \"App.Environment\", id: \"#{SecureRandom.uuid}\"\n"

      exporter.send(:restore_embedded_sources, [
                      {
                        path: relative, contents: legacy,
                        sha256: Digest::SHA256.hexdigest(legacy), mode: 0o644
                      }
                    ])

      expect(File.read(generated)).to eq("mendix_name \"App.Environment\"\n")
    end
  end

  it 'regenerates standard legacy services but preserves custom Ruby methods' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    legacy = <<~RUBY
      class Run < Mxrb::RubyApp::Service
        mendix_name "App.Run", id: "#{SecureRandom.uuid}"
        def call(**arguments)
          native_call(arguments)
        end
      end
    RUBY
    custom = legacy.sub('native_call(arguments)', 'CustomRunner.call(arguments)')

    expect(exporter.send(:regenerate_legacy_public_projection?,
                         'app/services/app/run.rb', legacy, __FILE__)).to be(true)
    expect(exporter.send(:regenerate_legacy_public_projection?,
                         'app/services/app/run.rb', custom, __FILE__)).to be(false)
    expect(exporter.send(:regenerate_legacy_public_projection?,
                         'app/models/app/item.rb', custom, __FILE__)).to be(false)
    expect(exporter.send(:regenerate_legacy_public_projection?,
                         'config/adapters.rb', legacy, __FILE__)).to be(false)
    expect(exporter.send(:regenerate_legacy_public_projection?,
                         'app/services/app/run.rb', legacy, '/missing/generated.rb')).to be(false)
  end
end
# rubocop:enable Metrics/BlockLength
