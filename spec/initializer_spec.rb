# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Initializer do
  it 'creates a buildable scaffold with a default navigation home' do
    Dir.mktmpdir do |dir|
      result = described_class.new('vet_clinic').scaffold(into: dir)
      expected = [
        'Gemfile', 'project.rb', 'modules/VetClinic/module.rb',
        'modules/VetClinic/domain/model.rb',
        'modules/VetClinic/application/application.rb',
        'modules/VetClinic/domain/entities/.keep',
        'modules/VetClinic/presentation/presentation.rb',
        'modules/VetClinic/presentation/pages/home.rb'
      ].map { File.join(result.root, _1) }
      expect(result.root).to eq(File.join(dir, 'vet_clinic'))
      expect(result.files).to eq(expected)
      expect(result.files).to all(satisfy { File.file?(_1) })
      expect(File.read(expected[1])).to include(
        'Mxrb.define', 'mendix_version "11.12.1"',
        'home_page: "VetClinic.Home"', 'app_title: "VetClinic"',
        'modules", "VetClinic", "module.rb"'
      )
      expect(File.read(expected[2])).to include(
        'self.module :VetClinic', 'domain", "model.rb"',
        'application", "application.rb"', 'presentation", "presentation.rb"'
      )
      expect(File.read(expected[3])).to include(
        'evaluate_dir File.join(__dir__, "enumerations")',
        'evaluate_dir File.join(__dir__, "entities")'
      )
      expect(File.read(expected[4])).to include(
        'evaluate_dir File.join(__dir__, "use_cases")',
        'evaluate_dir File.join(__dir__, "validations")',
        'evaluate_dir File.join(__dir__, "queries")'
      )
      expect(File.read(expected[5])).to be_empty
      expect(File.read(expected[6])).to include(
        'layout :ApplicationLayout',
        'evaluate_dir File.join(__dir__, "pages")',
        'evaluate_dir File.join(__dir__, "client_actions")'
      )
      expect(File.read(expected[7])).to include(
        'page :Home', 'title "VetClinic"', 'layout "VetClinic.ApplicationLayout"'
      )

      load expected[1]
      mpr = File.join(result.root, 'VetClinic.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      expect(Mxrb.open(mpr) { _1.modules.map(&:name) }).to eq(['VetClinic'])
      expect(Mxrb.open(mpr) { _1.navigation.profiles.map(&:name) }).to eq(['Responsive'])
      expect(Mxrb.open(mpr) { _1.navigation.profiles.first.home_page }).to eq('VetClinic.Home')
    end
  end

  it 'normalizes snake case and common lowercase compounds while preserving PascalCase' do
    Dir.mktmpdir do |dir|
      values = {
        'my_app' => 'MyApp', 'vetclinic' => 'VetClinic',
        'vetclinic2' => 'VetClinic2', 'ConnectorKitDemo' => 'ConnectorKitDemo'
      }
      values.each do |name, module_name|
        result = described_class.new(name).scaffold(into: dir)
        expect(result.files).to include(
          File.join(result.root, 'modules', module_name, 'module.rb')
        )
      end
    end
  end

  it 'rejects unsafe names and aborts without touching an existing directory' do
    ['', '../escape', 'with/slash', '1project', "nul\0name"].each do |name|
      expect { described_class.new(name) }.to raise_error(ArgumentError, /project name/)
    end
    Dir.mktmpdir do |dir|
      existing = File.join(dir, 'existing')
      FileUtils.mkdir_p(existing)
      File.write(File.join(existing, 'keep.txt'), 'keep')
      expect { described_class.new('existing').scaffold(into: dir) }
        .to raise_error(SystemExit)
      expect(File.read(File.join(existing, 'keep.txt'))).to eq('keep')
    end
  end

  it 'removes its private staging directory when a write fails' do
    Dir.mktmpdir do |dir|
      allow(File).to receive(:binwrite).and_raise(IOError, 'disk full')
      expect { described_class.new('failed_app').scaffold(into: dir) }
        .to raise_error(IOError, /disk full/)
      expect(Dir.children(dir)).to be_empty
    end
  end

  it 'exposes init through the CLI and prints every created file' do
    command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'init', 'my_app']
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(*command, chdir: dir)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include(
        'create', 'my_app/Gemfile', 'my_app/project.rb',
        'my_app/modules/MyApp/module.rb',
        'my_app/modules/MyApp/application/application.rb',
        'my_app/modules/MyApp/domain/entities/.keep',
        'my_app/modules/MyApp/presentation/pages/home.rb',
        'cd ', 'bundle exec mxrb generate project.rb'
      )
      expect(File).to exist(File.join(dir, 'my_app', 'modules', 'MyApp', 'domain', 'model.rb'))
    end
  end

  it 'can pin the generated Gemfile to a local MXRB checkout through the CLI' do
    command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'init', 'local_app',
               '--mxrb-path', File.expand_path('..', __dir__)]
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3(*command, chdir: dir)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(File.read(File.join(dir, 'local_app', 'Gemfile'))).to include(
        %(gem "mxrb", path: "#{File.expand_path('..', __dir__)}")
      )
    end
  end

  it 'scaffolds and connects an additional module that generates a valid MPR' do
    Dir.mktmpdir do |dir|
      project = described_class.new('vetclinic').scaffold(into: dir)
      result = Mxrb::ModuleInitializer.new('appointments').scaffold(into: project.root)
      expected = [
        'module.rb', 'domain/model.rb', 'application/application.rb',
        'domain/entities/.keep', 'presentation/presentation.rb',
        'presentation/pages/home.rb'
      ].map { File.join(result.root, _1) }

      expect(result.root).to eq(File.join(project.root, 'modules', 'Appointments'))
      expect(result.files).to eq(expected)
      expect(result.files).to all(satisfy { File.file?(_1) })
      expect(File.read(result.project_file)).to include(
        'evaluate File.join(__dir__, "modules", "Appointments", "module.rb")'
      )

      load File.join(project.root, 'project.rb')
      mpr = File.join(project.root, 'VetClinic.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      expect(Mxrb.open(mpr) { _1.modules.map(&:name) }).to eq(%w[VetClinic Appointments])
    end
  end

  it 'exposes module new through the CLI with snake-case normalization' do
    command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'module', 'new',
               'appointment_types']
    Dir.mktmpdir do |dir|
      project = described_class.new('clinic').scaffold(into: dir)
      stdout, stderr, status = Open3.capture3(*command, chdir: project.root)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include(
        'create', 'modules/AppointmentTypes/module.rb',
        'modules/AppointmentTypes/application/application.rb',
        'update', 'project.rb', 'bundle exec mxrb generate project.rb'
      )
    end
  end

  it 'rejects missing projects and preserves existing modules and project files' do
    Dir.mktmpdir do |dir|
      expect do
        Mxrb::ModuleInitializer.new('appointments').scaffold(into: dir)
      end.to raise_error(ArgumentError, /project\.rb not found/)

      project = described_class.new('clinic').scaffold(into: dir)
      project_file = File.join(project.root, 'project.rb')
      original = File.binread(project_file)
      existing = File.join(project.root, 'modules', 'Appointments')
      FileUtils.mkdir_p(existing)
      File.write(File.join(existing, 'keep.txt'), 'keep')

      expect do
        Mxrb::ModuleInitializer.new('appointments').scaffold(into: project.root)
      end.to raise_error(SystemExit)
      expect(File.binread(project_file)).to eq(original)
      expect(File.read(File.join(existing, 'keep.txt'))).to eq('keep')
    end
  end

  it 'rejects unsafe project files and rolls back when the atomic update fails' do
    Dir.mktmpdir do |dir|
      project = described_class.new('clinic').scaffold(into: dir)
      project_file = File.join(project.root, 'project.rb')

      File.binwrite(project_file, "puts 'not an mxrb project'\n")
      expect do
        Mxrb::ModuleInitializer.new('broken').scaffold(into: project.root)
      end.to raise_error(ArgumentError, /Mxrb\.define/)

      File.binwrite(project_file, 'Mxrb.define("Clinic.mpr") do')
      expect do
        Mxrb::ModuleInitializer.new('unclosed').scaffold(into: project.root)
      end.to raise_error(ArgumentError, /closing end/)

      File.binwrite(project_file, <<~RUBY)
        Mxrb.define("Clinic.mpr") do
          evaluate File.join(__dir__, "modules", "Duplicate", "module.rb")
        end
      RUBY
      expect do
        Mxrb::ModuleInitializer.new('duplicate').scaffold(into: project.root)
      end.to raise_error(ArgumentError, /already loads Duplicate/)

      File.binwrite(project_file, "Mxrb.define(\"Clinic.mpr\") do\nend\n")
      original = File.binread(project_file)
      renames = 0
      allow(File).to receive(:rename).and_wrap_original do |method, *args|
        renames += 1
        raise IOError, 'rename failed' if renames == 2

        method.call(*args)
      end
      expect do
        Mxrb::ModuleInitializer.new('rollback').scaffold(into: project.root)
      end.to raise_error(IOError, /rename failed/)
      expect(File.binread(project_file)).to eq(original)
      expect(File).not_to exist(File.join(project.root, 'modules', 'Rollback'))
    end
  end
end
# rubocop:enable Metrics/BlockLength
