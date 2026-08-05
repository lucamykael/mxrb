# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Scaffold::Generator do
  def project_in(dir)
    Mxrb::Initializer.new('scaffold_app').scaffold(into: dir).root
  end

  def scaffold(root, kind, name = nil)
    described_class.new(kind, name, target: root).scaffold
  end

  it 'scaffolds the prioritized domain and application artifacts' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      results = [
        scaffold(root, :entity, 'ScaffoldApp.Animal'),
        scaffold(root, :enumeration, 'ScaffoldApp.AnimalSpecies'),
        scaffold(root, :use_case, 'ScaffoldApp.ACT_CreateAnimal'),
        scaffold(root, :validation, 'ScaffoldApp.VAL_Animal'),
        scaffold(root, :query, 'ScaffoldApp.QRY_Animals'),
        scaffold(root, :constant, 'ScaffoldApp.ApiUrl')
      ]

      entity = results.first.files.fetch(0)
      expect(File.read(entity)).to include('entity :Animal', 'docs/pt-BR/entity-dsl.md')
      expect(File.read(entity)).not_to match(/string :|integer :/)
      expect(File.read(File.join(root, 'modules/ScaffoldApp/domain/model.rb')))
        .to include('evaluate_dir File.join(__dir__, "constants")')

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      Mxrb.open(mpr) do |project|
        mod = project.modules.first
        expect(mod.entities.map(&:name)).to eq(['Animal'])
        expect(mod.enumerations.map { _1['Name'] }).to eq(['AnimalSpecies'])
        expect(mod.microflows.map(&:name)).to include('ACT_CreateAnimal', 'VAL_Animal', 'QRY_Animals')
        expect(mod.constants.map { _1['Name'] }).to eq(['ApiUrl'])
      end
    end
  end

  it 'initializes presentation and security and scaffolds pages and nanoflows' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      presentation = scaffold(root, :presentation, 'ScaffoldApp')
      scaffold(root, :page, 'ScaffoldApp.AnimalOverview')
      scaffold(root, :nanoflow, 'ScaffoldApp.NAN_OpenAnimal')
      scaffold(root, :security, 'ScaffoldApp')

      expect(presentation.files.size).to eq(3)
      expect(File.read(File.join(root, 'modules/ScaffoldApp/presentation/presentation.rb')))
        .to include('layout :ApplicationLayout')
      expect(File.read(File.join(root, 'modules/ScaffoldApp/presentation/pages/animal_overview.rb')))
        .to include('layout "ScaffoldApp.ApplicationLayout"')
      module_source = File.read(File.join(root, 'modules/ScaffoldApp/module.rb'))
      expect(module_source).to include(
        'presentation", "presentation.rb"', 'security", "security.rb"'
      )
      expect do
        scaffold(root, :presentation, 'ScaffoldApp')
      end.to raise_error(SystemExit, /already initialized/)
      expect(File.read(File.join(root, 'project.rb'))).to include(
        'security_level "CheckEverything"', 'ScaffoldApp.Administrator'
      )

      load File.join(root, 'project.rb')
      mpr_file = Mxrb::IO::MprFile.open(File.join(root, 'ScaffoldApp.mpr'), readonly: true)
      security = mpr_file.all_units.map { mpr_file.parse_contents(_1) }
                         .find { _1['$Type'] == 'Security$ProjectSecurity' }
      expect(security['AdminUserRole']).to eq('Administrator')
      mpr_file.close
      Mxrb.open(File.join(root, 'ScaffoldApp.mpr')) do |project|
        mod = project.modules.first
        expect(mod.pages.map(&:name)).to contain_exactly('Home', 'AnimalOverview')
        expect(mod.nanoflows.map(&:name)).to eq(['NAN_OpenAnimal'])
        expect(mod.module_roles.map { _1[:name] }).to eq(%w[User Administrator])
        expect(project.architecture_definition.dig(:security, :security_level)).to eq('CheckEverything')
      end
    end
  end

  it 'scaffolds an executable page to nanoflow to microflow chain' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      result = described_class.new(
        :page, 'ScaffoldApp.Order', target: root, page_chain: 'page:nanoflow:microflow'
      ).scaffold

      expected = %w[
        modules/ScaffoldApp/domain/entities/order.rb
        modules/ScaffoldApp/application/use_cases/act_load_order.rb
        modules/ScaffoldApp/application/use_cases/act_refresh_order.rb
        modules/ScaffoldApp/presentation/client_actions/nan_refresh_order.rb
        modules/ScaffoldApp/presentation/pages/order.rb
        app/navigation/responsive/scaffold_app_order.rb
      ].map { File.join(root, _1) }
      expect(result.files).to include(*expected)
      expect(File.read(expected[0])).to include(
        'entity :Order', 'string :Reference', 'decimal :Total', 'boolean :Active'
      )
      expect(File.read(expected[1])).to include(
        'microflow :ACT_LoadOrder', 'create_object "ScaffoldApp.Order"',
        'return_value :record'
      )
      expect(File.read(expected[2])).to include(
        'microflow :ACT_RefreshOrder',
        'log_message "Order refreshed from the page scaffold"'
      )
      expect(File.read(expected[3])).to include(
        'nanoflow :NAN_RefreshOrder', 'show_message "Order refreshed"',
        'call_microflow "ScaffoldApp.ACT_RefreshOrder"'
      )
      expect(File.read(expected[4])).to include(
        'page :Order', 'data_source microflow: "ScaffoldApp.ACT_LoadOrder"',
        'number_input :total', 'action: :save_changes',
        'nanoflow: "ScaffoldApp.NAN_RefreshOrder"'
      )
      expect(File.read(expected[5])).to include(
        'item "Order", page: "ScaffoldApp.Order", icon: "file"'
      )

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      source = Mxrb::Compiler::SourceModel.read(mpr)
      expect(Mxrb::Compiler::CompatibilityAnalyzer.new(mpr, source:).analyze).to be_compatible
      Mxrb.open(mpr) do |project|
        mod = project.modules.first
        expect(mod.entities.map(&:name)).to eq(['Order'])
        expect(mod.pages.map(&:name)).to contain_exactly('Home', 'Order')
        expect(mod.microflows.map(&:name)).to include('ACT_LoadOrder', 'ACT_RefreshOrder')
        expect(mod.nanoflows.map(&:name)).to include('NAN_RefreshOrder')
        expect(project.navigation.profiles.first.menu_items.first[:page]).to eq('ScaffoldApp.Order')
      end
    end
  end

  it 'scaffolds a page that calls a microflow directly when requested' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      result = described_class.new(
        :page, 'ScaffoldApp.Order', target: root, page_chain: 'page:microflow'
      ).scaffold
      page = File.join(root, 'modules/ScaffoldApp/presentation/pages/order.rb')
      nanoflow = File.join(
        root, 'modules/ScaffoldApp/presentation/client_actions/nan_refresh_order.rb'
      )

      expect(File.read(page)).to include(
        'on_click microflow: "ScaffoldApp.ACT_RefreshOrder"'
      )
      expect(result.files).not_to include(nanoflow)
      expect(File).not_to exist(nanoflow)

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      source = Mxrb::Compiler::SourceModel.read(mpr)
      expect(Mxrb::Compiler::CompatibilityAnalyzer.new(mpr, source:).analyze).to be_compatible
      Mxrb.open(mpr) do |project|
        mod = project.modules.first
        expect(mod.microflows.map(&:name)).to include('ACT_LoadOrder', 'ACT_RefreshOrder')
        expect(mod.nanoflows).to be_empty
      end
    end
  end

  it 'scaffolds a page that calls a client nanoflow without a server action' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      result = described_class.new(
        :page, 'ScaffoldApp.Order', target: root, page_chain: 'page:nanoflow'
      ).scaffold
      nanoflow = File.join(
        root, 'modules/ScaffoldApp/presentation/client_actions/nan_refresh_order.rb'
      )
      action = File.join(root, 'modules/ScaffoldApp/application/use_cases/act_refresh_order.rb')
      page = File.join(root, 'modules/ScaffoldApp/presentation/pages/order.rb')

      expect(File.read(nanoflow)).to include(
        'nanoflow :NAN_RefreshOrder', 'show_message "Order refreshed"'
      )
      expect(File.read(nanoflow)).not_to include('call_microflow')
      expect(File.read(page)).to include('on_click nanoflow: "ScaffoldApp.NAN_RefreshOrder"')
      expect(result.files).not_to include(action)
      expect(File).not_to exist(action)

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      source = Mxrb::Compiler::SourceModel.read(mpr)
      expect(Mxrb::Compiler::CompatibilityAnalyzer.new(mpr, source:).analyze).to be_compatible
      Mxrb.open(mpr) do |project|
        mod = project.modules.first
        expect(mod.microflows.map(&:name)).to eq(['ACT_LoadOrder'])
        expect(mod.nanoflows.map(&:name)).to eq(['NAN_RefreshOrder'])
      end
    end
  end

  it 'lists and materializes every audited page template as editable Mendix pages' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      templates = {
        'starter' => 'StarterPage', 'blank' => 'BlankPage',
        'dashboard' => 'DashboardPage', 'form-vertical' => 'FormPage'
      }
      templates.each do |template, name|
        described_class.new(
          :page, "ScaffoldApp.#{name}", target: root, page_template: template
        ).scaffold
      end

      dashboard = File.join(root, 'modules/ScaffoldApp/presentation/pages/dashboard_page.rb')
      form = File.join(root, 'modules/ScaffoldApp/presentation/pages/form_page.rb')
      expect(File.read(dashboard)).to include(
        'mxrb-dashboard-grid', 'PRIMARY', 'SECONDARY', 'ACTIVITY'
      )
      expect(File.read(form)).to include(
        'data_source microflow: "ScaffoldApp.ACT_LoadFormPage"'
      )
      expect(File).to exist(File.join(root, 'modules/ScaffoldApp/domain/entities/form_page.rb'))

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      source = Mxrb::Compiler::SourceModel.read(mpr)
      expect(Mxrb::Compiler::CompatibilityAnalyzer.new(mpr, source:).analyze).to be_compatible
      Mxrb.open(mpr) do |project|
        expect(project.modules.first.pages.map(&:name)).to include(*templates.values)
      end
    end
  end

  it 'combines a dashboard template with a page to nanoflow chain' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      described_class.new(
        :page, 'ScaffoldApp.Operations', target: root,
                                         page_template: 'dashboard', page_chain:    'page:nanoflow'
      ).scaffold
      page = File.join(root, 'modules/ScaffoldApp/presentation/pages/operations.rb')

      expect(File.read(page)).to include(
        'mxrb-dashboard-grid', 'on_click nanoflow: "ScaffoldApp.NAN_RefreshOperations"'
      )
      expect(File).not_to exist(
        File.join(root, 'modules/ScaffoldApp/domain/entities/operations.rb')
      )
      load File.join(root, 'project.rb')
      expect(Mxrb.validate(File.join(root, 'ScaffoldApp.mpr'))).to be_valid
    end
  end

  it 'rejects unsupported page chains before creating files' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)

      expect do
        described_class.new(
          :page, 'ScaffoldApp.Order', target: root, page_chain: 'page:microflow:nanoflow'
        ).scaffold
      end.to raise_error(ArgumentError, /page chain must be one of/)
      expect do
        described_class.new(
          :page, 'ScaffoldApp.Other', target: root, page_template: 'unknown'
        ).scaffold
      end.to raise_error(ArgumentError, /page template must be one of/)
      expect do
        described_class.new(:entity, 'ScaffoldApp.Other', target: root, unsupported: true)
      end.to raise_error(ArgumentError, /unknown generator options/)
      expect(File).not_to exist(File.join(root, 'modules/ScaffoldApp/domain/entities/order.rb'))
    end
  end

  it 'fails atomically when page-chain navigation is not connected' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      project = File.join(root, 'project.rb')
      File.write(
        project,
        File.read(project).sub(
          'evaluate_dir File.join(__dir__, "app", "navigation", "responsive")',
          '# navigation aggregator intentionally absent'
        )
      )

      expect do
        described_class.new(
          :page, 'ScaffoldApp.Order', target: root, page_chain: 'page:nanoflow:microflow'
        ).scaffold
      end
        .to raise_error(ArgumentError, /generated Responsive navigation aggregator/)
      expect(File).not_to exist(File.join(root, 'modules/ScaffoldApp/domain/entities/order.rb'))
    end
  end

  it 'does not duplicate project security and diagnoses malformed project definitions' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      scaffold(root, :security, 'ScaffoldApp')
      generator = described_class.new(:security, 'ScaffoldApp', target: root)
      expect { generator.send(:connect_project_security, 'ScaffoldApp') }.not_to raise_error

      malformed = File.join(dir, 'malformed')
      FileUtils.mkdir_p(malformed)
      File.write(File.join(malformed, 'project.rb'), "Mxrb.define('App.mpr') do\nend\n")
      generator = described_class.new(:security, 'App', target: malformed)
      expect { generator.send(:connect_project_security, 'App') }
        .to raise_error(ArgumentError, /mendix_version not found/)
    end
  end

  it 'scaffolds repositories, jobs, and every infrastructure adapter' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      scaffold(root, :repository, 'ScaffoldApp.AnimalRepository')
      scaffold(root, :scheduled_event, 'ScaffoldApp.Cleanup')
      scaffold(root, :integration, 'ScaffoldApp.PetApi')
      scaffold(root, :published_rest, 'ScaffoldApp.AnimalsApi')
      scaffold(root, :consumed_rest, 'ScaffoldApp.ExternalPets')
      scaffold(root, :java_action, 'ScaffoldApp.ParseDocument')

      infrastructure = File.join(root, 'modules/ScaffoldApp/infrastructure')
      expect(File.read(File.join(infrastructure, 'endpoints/animals_api.rb')))
        .to include('native Studio Pro/baseline operation')
      expect(File.read(File.join(infrastructure, 'actions/parse_document.rb')))
        .to include('# call_java')

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      Mxrb.open(mpr) do |project|
        mod = project.modules.first
        expect(mod.microflows.map(&:name)).to include(
          'AnimalRepositoryImplementation', 'Cleanup', 'PetApi',
          'AnimalsApi', 'ExternalPets', 'ParseDocument'
        )
        expect(mod.scheduled_events.map { _1['Name'] }).to eq(['Cleanup'])
      end
    end
  end

  it 'scaffolds project-level tests, evaluations, design, and GitHub CI' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      functional = scaffold(root, :functional_test, 'ScaffoldApp.ACT_CreateAnimal')
      evaluation = scaffold(root, :evaluation, 'architecture')
      design = scaffold(root, :design)
      ci = scaffold(root, :ci, 'github')

      definition = Mxrb.functional_definition(functional.files.fetch(0))
      expect(definition.tests.first.target).to eq('ScaffoldApp.ACT_CreateAnimal')
      expect(File.read(evaluation.files.fetch(0))).to include('no_call_cycles')
      expect(File.read(ci.files.fetch(0))).to include('ruby/setup-ruby@v1', 'bundle exec rspec')
      expect(design.files).to be_empty
      expect(File.read(File.join(root, 'theme', 'web', 'settings.json')))
        .to include('theme.compiled.css')

      load File.join(root, 'project.rb')
      mpr = File.join(root, 'ScaffoldApp.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      result = Mxrb.open(mpr) do |project|
        Mxrb::Evaluation::Suite.new(project).evaluate(evaluation.files.fetch(0)).run
      end
      expect(result).to be_passed
    end
  end

  it 'connects new artifacts to explicit aggregators in an exported Ruby project' do
    Dir.mktmpdir do |dir|
      source_root = project_in(dir)
      load File.join(source_root, 'project.rb')
      source_mpr = File.join(source_root, 'ScaffoldApp.mpr')
      exported = File.join(dir, 'exported')
      Mxrb::Exporter.new(source_mpr, exported).export!

      scaffold(exported, :entity, 'ScaffoldApp.Animal')
      scaffold(exported, :use_case, 'ScaffoldApp.ACT_CreateAnimal')
      scaffold(exported, :page, 'ScaffoldApp.AnimalOverview')
      scaffold(exported, :nanoflow, 'ScaffoldApp.NAN_OpenAnimal')
      scaffold(exported, :repository, 'ScaffoldApp.AnimalRepository')
      scaffold(exported, :scheduled_event, 'ScaffoldApp.Cleanup')
      scaffold(exported, :integration, 'ScaffoldApp.PetApi')

      expect(File.read(File.join(exported, 'modules/ScaffoldApp/domain/model.rb')))
        .to include('evaluate File.join(__dir__, "entities", "animal.rb")')
      expect(File.read(File.join(exported, 'modules/ScaffoldApp/application/application.rb')))
        .to include(
          'evaluate File.join(__dir__, "use_cases", "act_create_animal.rb")',
          'evaluate File.join(__dir__, "repositories", "animal_repository.rb")',
          'evaluate File.join(__dir__, "jobs", "cleanup.rb")'
        )
      expect(File.read(File.join(exported, 'modules/ScaffoldApp/presentation/presentation.rb')))
        .to include(
          'evaluate File.join(__dir__, "pages", "animal_overview.rb")',
          'evaluate File.join(__dir__, "client_actions", "nan_open_animal.rb")'
        )
      expect(File.read(File.join(exported, 'modules/ScaffoldApp/infrastructure/infrastructure.rb')))
        .to include(
          'evaluate File.join(__dir__, "repositories", "animal_repository_implementation.rb")',
          'evaluate File.join(__dir__, "integrations", "pet_api.rb")'
        )

      rebuilt = File.join(dir, 'rebuilt.mpr')
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = rebuilt
      load File.join(exported, 'project.rb')
      ENV['MXRB_OUTPUT_PATH'] = previous

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        mod = project.modules.first
        expect(mod.entities.map(&:name)).to include('Animal')
        expect(mod.pages.map(&:name)).to include('AnimalOverview')
        expect(mod.nanoflows.map(&:name)).to include('NAN_OpenAnimal')
        expect(mod.microflows.map(&:name)).to include(
          'ACT_CreateAnimal', 'AnimalRepositoryImplementation', 'Cleanup', 'PetApi'
        )
        expect(mod.scheduled_events.map { _1['Name'] }).to include('Cleanup')
      end
    ensure
      previous.nil? ? ENV.delete('MXRB_OUTPUT_PATH') : ENV['MXRB_OUTPUT_PATH'] = previous
    end
  end

  it 'rejects invalid names, missing roots, missing modules, and unsupported CI providers' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      expect { scaffold(root, :entity, 'Animal') }
        .to raise_error(ArgumentError, /Module\.Artifact/)
      expect { scaffold(root, :entity, 'Bad-Module.Animal') }
        .to raise_error(ArgumentError, /module name/)
      expect { scaffold(root, :entity, 'Missing.Animal') }
        .to raise_error(ArgumentError, /module not found/)
      expect { scaffold(dir, :evaluation, 'architecture') }
        .to raise_error(ArgumentError, /project\.rb not found/)
      expect { scaffold(root, :ci, 'gitlab') }
        .to raise_error(ArgumentError, /provider must be github/)
      expect { scaffold(root, :design, 'unexpected') }
        .to raise_error(SystemExit, /Usage/)
    end
  end

  it 'does not overwrite files and rejects malformed aggregators' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      scaffold(root, :entity, 'ScaffoldApp.Animal')
      expect { scaffold(root, :entity, 'ScaffoldApp.Animal') }
        .to raise_error(SystemExit, /already exists/)

      model = File.join(root, 'modules/ScaffoldApp/domain/model.rb')
      FileUtils.rm_f(model)
      expect { scaffold(root, :constant, 'ScaffoldApp.ApiUrl') }
        .to raise_error(ArgumentError, /aggregator not found/)

      module_file = File.join(root, 'modules/ScaffoldApp/module.rb')
      File.binwrite(module_file, 'self.module :ScaffoldApp do')
      expect { scaffold(root, :presentation, 'ScaffoldApp') }
        .to raise_error(ArgumentError, /closing end not found/)
    end
  end

  it 'leaves already connected aggregators unchanged' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      generator = described_class.new(:entity, 'ScaffoldApp.Animal', target: root)
      project = File.join(root, 'project.rb')
      project_before = File.binread(project)

      generator.send(:connect_project_file, 'modules', 'ScaffoldApp', 'module.rb')

      expect(generator.instance_variable_get(:@transaction).updated).to be_empty
      expect(File.binread(project)).to eq(project_before)
    end
  end

  it 'stages a missing project-level aggregator connection' do
    Dir.mktmpdir do |dir|
      root = project_in(dir)
      project = File.join(root, 'project.rb')
      source = File.binread(project).sub(
        /^\s*evaluate File\.join\(__dir__, "app", "design_system", "design_system\.rb"\)\n/,
        ''
      )
      File.binwrite(project, source)
      generator = described_class.new(:design, target: root)

      generator.send(:connect_project_file, 'app', 'design_system', 'design_system.rb')

      transaction = generator.instance_variable_get(:@transaction)
      expect(transaction.updated).to eq([project])
      expect(transaction.content(project))
        .to include('evaluate File.join(__dir__, "app", "design_system", "design_system.rb")')
    end
  end
end

RSpec.describe Mxrb::Scaffold::Transaction do
  it 'reads pending content, skips unchanged writes, and rolls back applied changes' do
    Dir.mktmpdir do |dir|
      existing = File.join(dir, 'existing.rb')
      created = File.join(dir, 'created.rb')
      File.binwrite(existing, 'original')
      transaction = described_class.new
      transaction.write(existing, 'updated')
      transaction.write(existing, 'updated')
      transaction.write(created, 'new')
      expect(transaction.content(existing)).to eq('updated')
      expect(transaction.updated).to eq([existing])

      renames = 0
      allow(File).to receive(:rename).and_wrap_original do |method, *args|
        renames += 1
        raise IOError, 'atomic failure' if renames == 2

        method.call(*args)
      end
      expect { transaction.commit }.to raise_error(IOError, /atomic failure/)
      expect(File.binread(existing)).to eq('original')
      expect(File).not_to exist(created)
    end
  end

  it 'keeps one update entry and rolls back a newly created file' do
    Dir.mktmpdir do |dir|
      created = File.join(dir, 'created.rb')
      existing = File.join(dir, 'existing.rb')
      File.binwrite(existing, 'original')
      transaction = described_class.new
      transaction.create(created, 'new')
      transaction.write(existing, 'updated')
      transaction.write(existing, 'updated again')
      expect(transaction.updated).to eq([existing])

      renames = 0
      allow(File).to receive(:rename).and_wrap_original do |method, *args|
        renames += 1
        raise IOError, 'atomic failure' if renames == 2

        method.call(*args)
      end
      expect { transaction.commit }.to raise_error(IOError, /atomic failure/)
      expect(File).not_to exist(created)
      expect(File.binread(existing)).to eq('original')
    end
  end
end

RSpec.describe Mxrb::Scaffold::CLI do
  it 'shows detailed help for every scaffold command' do
    Mxrb::Scaffold::Help::COMMANDS.each_key do |command|
      output = StringIO.new
      described_class.new(command, ['--help'], output:).run
      expect(output.string).to include("Usage: mxrb #{command}", '--target DIR', 'Documentation:')
    end
  end

  it 'runs a scaffold with --target and reports created files' do
    Dir.mktmpdir do |dir|
      root = Mxrb::Initializer.new('cli_app').scaffold(into: dir).root
      output = StringIO.new
      described_class.new(
        'entity', ['new', 'CliApp.Customer', '--target', root], output:
      ).run
      expect(output.string).to include('create', 'customer.rb', 'bundle exec mxrb generate')
    end
  end

  it 'accepts new, generate, and g plus every chain for the page scaffold' do
    Dir.mktmpdir do |dir|
      root = Mxrb::Initializer.new('cli_app').scaffold(into: dir).root
      {
        'new' => 'page:microflow',
        'generate' => 'page:nanoflow',
        'g' => 'page:nanoflow:microflow'
      }.each do |action, chain|
        output = StringIO.new
        described_class.new(
          'page', [
            action, 'CliApp.Order', '--chain', chain, '--target', root, '--dry-run'
          ], output:
        ).run
        expect(output.string).to include('would create', 'order.rb')
      end

      minimal = StringIO.new
      described_class.new(
        'page', ['new', 'CliApp.Order', '--target', root, '--dry-run'], output: minimal
      ).run
      expect(minimal.string).to include('would create', 'order.rb')
      expect(minimal.string).not_to include('act_refresh_order.rb')
    end
  end

  it 'renders the page-template catalog as a tree and JSON' do
    tree = StringIO.new
    described_class.new('page', ['templates'], output: tree).run
    expect(tree.string).to include(
      'Page templates', 'General', 'Dashboards', 'Forms', 'form-vertical'
    )

    json = StringIO.new
    described_class.new('page', %w[templates --json], output: json).run
    payload = JSON.parse(json.string)
    expect(payload.flat_map { _1.fetch('templates') }.map { _1.fetch('name') }).to contain_exactly(
      'starter', 'blank', 'dashboard', 'form-vertical'
    )

    expect { described_class.new('page', %w[templates --unknown]).run }
      .to raise_error(SystemExit, /Unknown arguments/)
  end

  it 'routes the public page alias and chain option through bin/mxrb' do
    Dir.mktmpdir do |dir|
      root = Mxrb::Initializer.new('cli_app').scaffold(into: dir).root
      executable = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'page']
      stdout, stderr, status = Open3.capture3(
        *executable, 'g', 'CliApp.Order', '--chain', 'page:microflow', '--target', root
      )

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('act_refresh_order.rb', 'order.rb')
      page = File.join(root, 'modules/CliApp/presentation/pages/order.rb')
      expect(File.read(page)).to include('on_click microflow: "CliApp.ACT_RefreshOrder"')
    end
  end

  it 'covers help placement and reports invalid command arguments' do
    output = StringIO.new
    described_class.new('entity', ['new', '--help'], output:).run
    expect(output.string).to include('Usage: mxrb entity')

    expect { described_class.new('entity', ['create']).run }
      .to raise_error(SystemExit, /Usage: mxrb entity/)
    expect { described_class.new('entity', %w[new invalid]).run }
      .to raise_error(SystemExit, /name must be qualified/)
    expect { described_class.new('entity', ['new', 'App.Item', '--extra']).run }
      .to raise_error(SystemExit, /Unknown arguments/)
    expect { described_class.new('entity', ['new', 'App.Item', '--target']).run }
      .to raise_error(SystemExit, /requires a value/)
  end

  it 'runs init and quiet commands without a target option' do
    Dir.mktmpdir do |dir|
      root = Mxrb::Initializer.new('cli_app').scaffold(into: dir).root
      Dir.chdir(root) do
        output = StringIO.new
        described_class.new('design', ['init'], output:).run
        expect(output.string).to include('Done. Run:')

        quiet = StringIO.new
        described_class.new('evaluation', %w[new architecture], output: quiet).run
        expect(quiet.string).to include('architecture.rb')
        expect(quiet.string).not_to include('Done. Run:')
      end
    end
  end

  it 'reuses the parsed scaffold name' do
    cli = described_class.new('entity', ['App.Item'])
    expect(cli.send(:scaffold_name)).to eq('App.Item')
    expect(cli.send(:scaffold_name)).to eq('App.Item')
  end
end
# rubocop:enable Metrics/BlockLength
