# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'platform expansion services' do
  describe Mxrb::Doctor do
    it 'reports healthy, warning, fallback Java, and invalid project states' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'project.rb'), "mendix_version \"11.12.1\"\n")
        module_dir = File.join(dir, 'modules', 'App')
        FileUtils.mkdir_p(module_dir)
        File.write(File.join(module_dir, 'module.rb'), <<~RUBY)
          evaluate_dir File.join(__dir__, "missing")
        RUBY
        File.write(File.join(dir, 'broken.mpr'), 'not sqlite')
        runtime = File.join(dir, 'runtime')
        Mxrb::Runtime::RUNTIME_REQUIRED_FILES.each do |relative|
          path = File.join(runtime, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, 'runtime')
        end

        failed = instance_double(Process::Status, success?: false)
        passed = instance_double(Process::Status, success?: true)
        runner = lambda do |command, _version|
          raise Errno::ENOENT if command == 'docker'

          ['', '', command.to_s.include?('java') ? passed : failed]
        end
        stub_const('ENV', ENV.to_h.merge('JAVA_HOME' => dir, 'MXRB_MENDIX_HOME' => runtime))
        report = described_class.new(File.join(dir, 'broken.mpr'), runner:).run
        expect(report.valid?).to be(false)
        expect(report.errors.map(&:name)).to include(:mpr, :bundle)
        expect(report.warnings.map(&:name)).to include(:aggregators, :docker)
        expect(report.checks.find { _1.name == :java }).to be_ok
        expect(report.checks.find { _1.name == :runtime }).to be_ok
      end
    end

    it 'reports missing files and toolchain and supports an older Ruby branch' do
      Dir.mktmpdir do |dir|
        failed = instance_double(Process::Status, success?: false)
        runner = ->(*_args) { ['', '', failed] }
        stub_const('RUBY_VERSION', '3.3.0')
        allow(Dir).to receive(:home).and_return(dir)
        stub_const('ENV', ENV.to_h.merge('JAVA_HOME' => '', 'MXRB_MENDIX_HOME' => ''))
        report = described_class.new(dir, runner:).run
        expect(report.errors.map(&:name)).to include(:ruby, :project, :modules, :bundle, :java)
        expect(report.warnings.map(&:name)).to include(:mpr, :docker, :runtime)
        expect(report.errors).not_to be_empty
      end
    end
  end

  describe Mxrb::ProjectLifecycle do
    it 'inspects, previews, applies upgrades, and produces a clean migration plan' do
      Dir.mktmpdir do |dir|
        project_file = File.join(dir, 'project.rb')
        mpr = File.join(dir, 'Clinic.mpr')
        File.write(project_file, <<~RUBY)
          require "mxrb"
          output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, "Clinic.mpr"))
          Mxrb.define(output) do
            mendix_version "11.12.1"
            self.module(:Clinic) { entity(:Animal) }
          end
        RUBY
        module_dir = File.join(dir, 'modules', 'Clinic')
        FileUtils.mkdir_p(module_dir)
        File.write(File.join(module_dir, 'module.rb'), '# module')
        load project_file
        lifecycle = described_class.new(dir)
        expect(lifecycle.inspect).to include(
          project_file: true, declared_version: '11.12.1', mprs: [mpr]
        )
        expect(lifecycle.upgrade('11.13.0')).to have_attributes(
          from: '11.12.1', to: '11.13.0', applied: false
        )
        stub_const('ENV', ENV.to_h.merge('MXRB_OUTPUT_PATH' => 'preserved'))
        plan = lifecycle.migration_plan
        expect(plan.current).to eq(mpr)
        expect(plan.generated).to end_with('Clinic.mpr')
        expect(plan.clean?).to be(true)
        expect(ENV['MXRB_OUTPUT_PATH']).to eq('preserved')
        expect(lifecycle.upgrade('11.13.0', apply: true).applied).to be(true)
        expect(File.read(project_file)).to include('mendix_version "11.13.0"')
      end
    end

    it 'rejects invalid versions and incomplete project roots' do
      Dir.mktmpdir do |dir|
        lifecycle = described_class.new(dir)
        expect(lifecycle.inspect).to include(project_file: false, declared_version: nil)
        expect { lifecycle.upgrade('next') }.to raise_error(ArgumentError, /MAJOR/)
        expect { lifecycle.upgrade('11.12.1') }.to raise_error(ArgumentError, /not found/)
        expect { lifecycle.migration_plan }.to raise_error(ArgumentError, /no current MPR/)
        File.write(File.join(dir, 'project.rb'), '# no version')
        expect { lifecycle.upgrade('11.12.1') }.to raise_error(ArgumentError, /no mendix_version/)
      end
    end

    it 'reports non-clean migration result branches' do
      change_set = Struct.new(:added, :removed, :changed)
      expect(Mxrb::MigrationResult.new('a', 'b', change_set.new([1], [], [])).clean?).to be(false)
    end
  end

  describe Mxrb::Scaffold::Registry do
    it 'stages, reads, removes, and refuses changed or unsafe files' do
      Dir.mktmpdir do |dir|
        source = File.join(dir, 'modules', 'App', 'domain', 'animal.rb')
        transaction = Mxrb::Scaffold::Transaction.new
        transaction.create(source, 'entity :Animal')
        registry_path = described_class.stage(
          transaction, root: dir, key: 'entity:App.Animal', files: [source]
        )
        transaction.commit
        registry = described_class.new(dir)
        expect(registry.entries).to have_key('entity:App.Animal')
        removal = registry.remove('entity:App.Animal')
        expect(removal.files).to eq([source])
        expect(File).not_to exist(source)
        expect(JSON.parse(File.read(registry_path))).to eq('scaffolds' => {})

        expect { registry.remove('missing') }.to raise_error(ArgumentError, /not registered/)
        File.write(registry_path, '{broken')
        expect { registry.entries }.to raise_error(ArgumentError, /invalid scaffold registry/)
        staged = Mxrb::Scaffold::Transaction.new
        staged.write(registry_path, '{broken')
        expect do
          described_class.stage(staged, root: dir, key: 'x', files: [])
        end.to raise_error(ArgumentError, /invalid scaffold registry/)

        payload = { 'scaffolds' => { 'unsafe' => { 'files' => [
          { 'path' => '../outside', 'sha256' => 'x' }
        ] } } }
        File.write(registry_path, JSON.generate(payload))
        expect { registry.remove('unsafe') }.to raise_error(ArgumentError, /unsafe/)
      end
    end

    it 'refuses deletion after a generated file changes or disappears' do
      Dir.mktmpdir do |dir|
        registry_path = File.join(dir, '.mxrb', 'scaffolds.json')
        FileUtils.mkdir_p(File.dirname(registry_path))
        file = File.join(dir, 'generated.rb')
        File.write(file, 'changed')
        entry = { 'path' => 'generated.rb', 'sha256' => Digest::SHA256.hexdigest('original') }
        File.write(registry_path, JSON.generate('scaffolds' => {
          'changed' => { 'files' => [entry] }, 'missing' => { 'files' => [entry.merge('path' => 'gone.rb')] }
        }))
        registry = described_class.new(dir)
        expect { registry.remove('changed') }.to raise_error(ArgumentError, /changed scaffold/)
        expect { registry.remove('missing') }.to raise_error(ArgumentError, /changed scaffold/)
      end
    end

    it 'returns an empty registry when none exists' do
      Dir.mktmpdir { |dir| expect(described_class.new(dir).entries).to eq({}) }
    end
  end

  describe Mxrb::Benchmark do
    it 'measures open, index, and validation operations deterministically' do
      project = double(all_units: [1, 2], semantic_index: double(artifacts: [1]))
      allow(Mxrb).to receive(:open).and_yield(project)
      allow(Mxrb).to receive(:validate).and_return(double(valid?: true))
      ticks = [0.0, 3.0, 3.0, 6.0, 6.0, 9.0]
      result = described_class.new('model.mpr', iterations: 3, clock: ->(*) { ticks.shift }).run
      expect(result).to have_attributes(
        iterations: 3, open_seconds: 1.0, index_seconds: 1.0,
        validate_seconds: 1.0, units: 2
      )
    end

    it 'rejects iteration counts outside the safe range' do
      expect { described_class.new('x', iterations: 0) }.to raise_error(ArgumentError, /between/)
      expect { described_class.new('x', iterations: 101) }.to raise_error(ArgumentError, /between/)
      expect { described_class.new('x', iterations: 'many') }.to raise_error(ArgumentError)
    end
  end

  describe 'small expansion edge contracts' do
    it 'uses a local mxrb path in initialized Gemfiles' do
      Dir.mktmpdir do |dir|
        root = Mxrb::Initializer.new('local_app', mxrb_path: File.expand_path('..', __dir__))
                                .scaffold(into: dir).root
        expect(File.read(File.join(root, 'Gemfile'))).to include('gem "mxrb", path:')
      end
    end

    it 'reads the lower-case legacy localizeDate property' do
      attribute = Mxrb::Model::Attribute.from_bson(
        'Name' => 'When', 'NewType' => {
          '$Type' => 'DomainModels$DateTimeAttributeType', 'localizeDate' => false
        }
      )
      expect(attribute.localize_date).to be(false)
    end

    it 'renders scaffold JSON and rejects a reserved Mendix entity name' do
      Dir.mktmpdir do |dir|
        root = Mxrb::Initializer.new('sample_app').scaffold(into: dir).root
        output = StringIO.new
        Mxrb::Scaffold::CLI.new(
          'entity', ['new', 'SampleApp.Animal', '--target', root, '--dry-run', '--json'],
          output:
        ).run
        expect(JSON.parse(output.string)).to include('kind' => 'entity', 'dry_run' => true)
        expect do
          Mxrb::Scaffold::Generator.new(:entity, 'SampleApp.Owner', target: root).scaffold
        end.to raise_error(ArgumentError, /reserved by Mendix/)
      end
    end

    it 'exports generalization, system members, and index-free compatibility doubles' do
      exporter = Mxrb::Exporter.new('input.mpr', Dir.pwd)
      entity = double(
        name: 'Account', attributes: [], persistable: true, documentation: '',
        generalization_target: 'System.User',
        system_members: { owner: true, changed_date: false }, indexes: [], access_rules: []
      )
      source = exporter.send(:entity_source, entity, double(entities: []), [])
      expect(source).to include('generalizes "System.User"', 'system_members owner: true')
    end

    it 'turns unexpected MPR validation failures into doctor errors' do
      doctor = Mxrb::Doctor.new(Dir.pwd)
      allow(Dir).to receive(:[]).and_return(['/tmp/broken.mpr'])
      allow(Mxrb).to receive(:validate).and_raise('boom')
      expect(doctor.send(:mpr_check)).to have_attributes(status: :error, message: 'boom')
    end
  end
end
# rubocop:enable Metrics/BlockLength
