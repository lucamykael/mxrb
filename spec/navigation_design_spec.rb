# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'native navigation and design systems' do
  it 'silently skips a missing Responsive navigation fragment directory' do
    builder = Mxrb::Dsl::NavigationProfileBuilder.new(:Responsive)

    expect(builder.evaluate_dir('/path/that/does/not/exist')).to be_nil
  end

  def define_native_project(path)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:App) do
        module_role :User
        page(:Home) { allowed_roles :User }
        page(:Login) { allowed_roles :User }
        microflow(:Dashboard) { allowed_roles :User }
      end
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['App.User']
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', sign_in_page: 'App.Login',
                             app_icon: 'icon.png', app_title: 'Application' do
          title :nl_NL, 'Applicatie'
          home_for :User, microflow: 'App.Dashboard'
          item 'Home', page: 'App.Home', icon: 'home' do
            item(
              { en_US: 'Dashboard', nl_NL: 'Overzicht' },
              microflow: 'App.Dashboard'
            )
            item 'Group'
          end
        end
      end
      design_system do
        color :foreground, value: '#777777'
        color :background, value: '#ffffff'
        theme :dark, inherits: :default do
          color :foreground, value: '#ffffff'
        end
        contrast foreground: :foreground, background: :background, level: :aaa
        forbid_literal_colors
      end
    end
  end

  it 'writes, reads, indexes and renames native navigation' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.mpr')
      define_native_project(path)

      Mxrb.open(path, readonly: false) do |project|
        profile = project.navigation.profiles.fetch(0)
        expect(profile).to have_attributes(
          name: 'Responsive', home_page: 'App.Home', sign_in_page: 'App.Login',
          app_icon: 'icon.png'
        )
        expect(profile.app_title).to eq('en_US' => 'Application', 'nl_NL' => 'Applicatie')
        expect(profile.role_homes).to eq([
                                           { role: 'User', microflow: 'App.Dashboard' }
                                         ])
        expect(profile.menu_items.dig(0, :items, 0, :microflow)).to eq('App.Dashboard')
        expect(profile.menu_items.dig(0, :items, 1, :page)).to be_nil

        navigation = project.find_artifact('Project.Navigation')
        expect(navigation.kind).to eq(:navigation_document)
        expect(project.references_from(navigation).map { _1.target.qualified_name })
          .to include('App.Home', 'App.Login', 'App.Dashboard')
        expect(project.plan_remove('App.Home')).not_to be_safe
        expect(project.analyze.diagnostics.map(&:rule))
          .not_to include(:inaccessible_navigation_home)

        plan = project.plan_rename('App.Home', to: 'Landing')
        expect(plan.changes.map(&:unit_id)).to include('architecture')
        plan.apply!
        expect(project.navigation.profiles.fetch(0).home_page).to eq('App.Landing')
        expect(project.architecture_definition.dig(
                 :navigation, :profiles, 0, :home_page
               )).to eq('App.Landing')
      end
    end
  end

  it 'exports and safely reconstructs project assets and rich contracts' do
    Dir.mktmpdir do |dir|
      source_dir = File.join(dir, 'source')
      FileUtils.mkdir_p(File.join(source_dir, 'theme', 'web'))
      FileUtils.mkdir_p(File.join(source_dir, 'vendorlib'))
      path = File.join(source_dir, 'app.mpr')
      define_native_project(path)
      File.write(
        File.join(source_dir, 'theme', 'web', '_theme-dark.scss'),
        ":root.theme-dark { --foreground: #fff; }\n"
      )
      File.binwrite(File.join(source_dir, 'vendorlib', 'driver.jar'), 'jar')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt', 'app.mpr')

      Mxrb::Exporter.new(path, exported).export!
      expect(File.read(File.join(exported, 'project.rb'))).to include('mendix_project_id ')
      expect(File.read(File.join(exported, 'app', 'navigation', 'navigation.rb')))
        .to include(
          'home_for', 'item "Home"', 'Applicatie',
          'evaluate_dir File.join(__dir__, "responsive")'
        )
      expect(File).to exist(File.join(exported, 'app', 'navigation', 'responsive', '.keep'))
      manifest = JSON.parse(File.read(File.join(exported, '.mxrb', 'assets.json')))
      expect(manifest.fetch('files')).to include(
        include('path' => 'theme/web/_theme-dark.scss'),
        include('path' => 'vendorlib/driver.jar')
      )

      begin
        ENV['MXRB_OUTPUT_PATH'] = rebuilt
        load File.join(exported, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      expect(File.binread(File.join(File.dirname(rebuilt), 'theme', 'web', '_theme-dark.scss')))
        .to eq(File.binread(File.join(source_dir, 'theme', 'web', '_theme-dark.scss')))
      expect(File.binread(File.join(File.dirname(rebuilt), 'vendorlib', 'driver.jar'))).to eq('jar')
      expect(Mxrb.compare(path, rebuilt)).to be_identical
    end
  end

  it 'scans tokens, catalogs, contrast and previews atomic literal migrations' do
    Dir.mktmpdir do |dir|
      theme = File.join(dir, 'theme', 'web')
      catalog = File.join(dir, 'themesource', 'atlas', 'web')
      FileUtils.mkdir_p([theme, catalog])
      File.write(
        File.join(theme, '_theme-dark.scss'),
        "// --ignored: #000;\n$brand: #123456;\n" \
        ":root { --ok: #fff; --broken: var(--missing); }\n"
      )
      File.write(File.join(catalog, 'design-properties.json'), '{"name":"Atlas"}')
      system = Mxrb::Model::DesignSystem.new(dir)

      expect(system.themes).to eq(['dark'])
      expect(system.tokens.map(&:name)).to contain_exactly('$brand', '--ok', '--broken')
      expect(system.catalogs.values.first).to eq('name' => 'Atlas')
      expect(system.unresolved_references.first.fetch(:reference)).to eq('--missing')
      expect(system.literal_colors.size).to eq(2)
      expect(system.contrast_ratio('#000', '#ffffff')).to eq(21.0)
      expect { system.contrast_ratio('red', '#fff') }
        .to raise_error(ArgumentError, /three- or six-digit/)

      plan = system.plan_literal_migration('#123456' => 'var(--brand)')
      expect(plan.changes.first.occurrences).to eq(1)
      expect(plan).not_to be_empty
      plan.apply!
      expect(File.read(File.join(theme, '_theme-dark.scss'))).to include('var(--brand)')
      expect(plan).to be_applied
      expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)
      expect(system.plan_literal_migration('#abcdef' => 'var(--none)')).to be_empty
    end
  end

  it 'resolves source token references against Mendix compiled theme-cache output' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'theme', 'web')
      cache = File.join(dir, 'theme-cache', 'web')
      FileUtils.mkdir_p([source, cache])
      File.write(File.join(source, 'theme.scss'), ':root { --button: var(--brand-primary-50); }')
      File.write(File.join(cache, 'theme.compiled.css'), ':root { --brand-primary-50: #eef; }')

      system = Mxrb::Model::DesignSystem.new(dir)
      expect(system.tokens.map(&:name)).to include('--button', '--brand-primary-50')
      expect(system.unresolved_references).to be_empty
    end
  end

  it 'derives navigation user roles from native project security without mxrb metadata' do
    analyzer = Mxrb::Semantic::Analyzer.allocate
    security = {
      'UserRoles' => Mxrb::IO::BsonCodec.build_array(
        [{
          'Name' => 'Trainee',
          'ModuleRoles' => Mxrb::IO::BsonCodec.build_array(['App.User'], marker: 1)
        }], marker: 2
      )
    }
    definition = analyzer.send(:native_security_definition, security)
    expect(definition.dig(:user_roles, 0)).to eq(
      name: 'Trainee', module_roles: ['App.User']
    )
  end

  it 'exposes design token scanning and preview/apply migration through the CLI' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'design.mpr')
      define_native_project(path)
      source = File.join(dir, 'theme', 'web', 'custom.scss')
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, '$legacy: #123456;')
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'design']

      stdout, stderr, status = Open3.capture3(*command, 'scan', path, '--json')
      payload = JSON.parse(stdout)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(payload.fetch('tokens').map { _1.fetch('name') }).to include('$legacy')

      stdout, stderr, status = Open3.capture3(
        *command, 'migrate', path, '#123456', 'var(--brand)', '--json'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to include('applied' => false, 'occurrences' => 1)
      expect(File.read(source)).to include('#123456')

      stdout, stderr, status = Open3.capture3(
        *command, 'migrate', path, '#123456', 'var(--brand)', '--apply'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('[mxrb] Applied: 1 replacements')
      expect(File.read(source)).to include('var(--brand)')
    end
  end

  it 'materializes typed tokens into an imported stylesheet and Studio design properties' do
    Dir.mktmpdir do |dir|
      theme = File.join(dir, 'theme', 'web')
      FileUtils.mkdir_p(theme)
      File.binwrite(File.join(theme, 'main.scss'), '@import "base";')
      definition = {
        tokens: [
          { kind: :color, name: :primaryColor, value: '#3366ff' },
          { kind: :spacing, name: '--content-gap', value: '1rem' },
          { kind: :typography, name: '$font-body', value: '"Inter", sans-serif' },
          { kind: :radius, name: :unset, value: nil }
        ],
        themes: [
          {
            name: :base, inherits: nil,
            tokens: [{ kind: :color, name: :surface, value: '#ffffff' }]
          },
          {
            name: :'Dark Mode', inherits: :base,
            tokens: [{ kind: :color, name: :surface, value: '#111111' }]
          },
          { name: :empty, inherits: nil, tokens: [] }
        ]
      }

      materializer = Mxrb::Model::DesignMaterializer.new(dir, definition)
      expect(materializer.materialize!).to equal(materializer)
      expect(materializer.materialize!).to equal(materializer)

      main = File.binread(File.join(theme, 'main.scss'))
      stylesheet = File.binread(File.join(theme, '_mxrb-design-system.scss'))
      catalog = JSON.parse(
        File.binread(File.join(dir, 'themesource', 'mxrb', 'web', 'design-properties.json'))
      )
      expect(main).to eq("@import \"base\";\n@import \"mxrb-design-system\";\n")
      expect(stylesheet).to include(
        '--color-primary-color: #3366ff;',
        '--content-gap: 1rem;',
        '--font-body: "Inter", sans-serif;',
        ':root[data-mxrb-theme="dark-mode"], .mxrb-theme-dark-mode',
        '--color-surface: #111111;'
      )
      expect(stylesheet.scan('--color-surface:').size).to eq(2)
      expect(stylesheet).not_to include('--radius-unset')
      expect(catalog.fetch('Widget')).to eq([
                                              {
                                                'category' => 'MXRB design system',
                                                'name' => 'Primary Color',
                                                'type' => 'ColorPicker',
                                                'property' => '--color-primary-color'
                                              }
                                            ])
      expect(Mxrb::Model::DesignSystem.new(dir).tokens.map(&:name)).to include(
        '--color-primary-color', '--content-gap', '--font-body'
      )
    end
  end

  it 'handles empty/external themes and rejects ambiguous token definitions' do
    Dir.mktmpdir do |dir|
      empty = Mxrb::Model::DesignMaterializer.new(dir, tokens: [], themes: [])
      expect(empty.materialize!).to equal(empty)
      expect(File).not_to exist(File.join(dir, 'theme'))

      missing_parent = {
        tokens: [],
        themes: [{ name: :dark, inherits: :missing, tokens: [] }]
      }
      cycle = {
        tokens: [],
        themes: [
          { name: :a, inherits: :b, tokens: [] },
          { name: :b, inherits: :a, tokens: [] }
        ]
      }
      unsafe = {
        tokens: [{ kind: :color, name: :bad, value: '#fff;' }],
        themes: []
      }
      blank = {
        tokens: [{ kind: :color, name: :bad, value: ' ' }],
        themes: []
      }
      invalid_name = {
        tokens: [{ kind: :color, name: '!!!', value: '#fff' }],
        themes: []
      }

      expect(Mxrb::Model::DesignMaterializer.new(dir, missing_parent).materialize!)
        .to be_a(Mxrb::Model::DesignMaterializer)
      expect { Mxrb::Model::DesignMaterializer.new(dir, cycle).materialize! }
        .to raise_error(Mxrb::SerializationError, /inheritance cycle/)
      expect { Mxrb::Model::DesignMaterializer.new(dir, unsafe).materialize! }
        .to raise_error(Mxrb::SerializationError, /unsafe.*value/)
      expect { Mxrb::Model::DesignMaterializer.new(dir, blank).materialize! }
        .to raise_error(Mxrb::SerializationError, /unsafe.*value/)
      expect { Mxrb::Model::DesignMaterializer.new(dir, invalid_name).materialize! }
        .to raise_error(Mxrb::SerializationError, /invalid.*name/)
    end
  end

  it 'parses legacy profiles and malformed design catalogs defensively' do
    legacy = Mxrb::Model::Navigation.new(
      'DesktopProfile' => {
        '$Type' => 'Navigation$NavigationProfile',
        'HomePage' => { 'Page' => '' },
        'ApplicationTitle' => 'Legacy'
      }
    )
    expect(legacy.profiles.first.name).to eq('Desktop')
    expect(legacy.profiles.first.home_page).to be_nil
    expect(legacy.profiles.first.app_title).to be_empty
    profile = Mxrb::Model::NavigationProfile.new(
      'Name' => 'Bare',
      'MenuItemCollection' => {
        'Items' => Mxrb::IO::BsonCodec.build_array([
                                                     { 'Caption' => nil, 'Action' => 'unknown', 'Items' => [] }
                                                   ])
      }
    )
    expect(profile.menu_items.first).to include(caption: {}, items: [])
    expect(Mxrb::Model::NavigationProfile.new('Name' => 'Empty').menu_items).to be_empty

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'themesource', 'bad', 'design-properties.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '{')
      expect(Mxrb::Model::DesignSystem.new(dir).catalogs.values).to eq([nil])
    end
  end

  it 'updates an existing legacy navigation document without modernizing its shape' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'legacy.mpr')
      define_native_project(path)
      definition = nil
      Mxrb.open(path, readonly: false) do |project|
        raw = project.all_units.find do |unit|
          project.parse_bson(unit)['$Type'] == 'Navigation$NavigationDocument'
        end
        modern = project.parse_bson(raw)
        profile = Mxrb::IO::BsonCodec.parse_array(modern.delete('Profiles'))[:items].first
        project.mpr.update_unit(raw.fetch('UnitID'), modern.merge('DesktopProfile' => profile))
        definition = project.architecture_definition
        definition[:navigation][:profiles][0][:name] = 'Desktop'
        definition[:navigation][:profiles][0][:kind] = 'Legacy'
      end

      Mxrb::Writer.new(path, definition).write!
      Mxrb.open(path) do |project|
        doc = project.navigation.raw_document
        expect(doc).not_to have_key('Profiles')
        expect(doc.dig('DesktopProfile', 'Kind')).to eq('Legacy')
      end
    end
  end

  it 'covers the complete optional navigation and theme DSL surface' do
    navigation = Mxrb::Dsl::NavigationBuilder.new
    navigation.profile(
      :Native, home_microflow: :App_Dashboard, kind: :Native,
               app_title: { pt_BR: 'Aplicativo' }
    ) do
      home_for :User, page: :App_Home
      item 'Parent' do
        item 'Nested' do
          item 'Leaf'
        end
      end
    end
    navigation.profile(:Simple, home_page: 'App.Home') { item 'Direct' }
    profile = navigation.to_h.fetch(:profiles).first
    expect(profile).to include(
      home_page: nil, home_microflow: 'App_Dashboard', kind: 'Native',
      app_title: { 'pt_BR' => 'Aplicativo' }
    )

    design = Mxrb::Dsl::DesignSystemBuilder.new
    design.theme(:plain)
    design.theme(:tokens) { spacing :unset }
    definition = design.to_h
    expect(definition.dig(:themes, 0, :inherits)).to be_nil
    expect(definition.dig(:themes, 1, :tokens, 0, :value)).to be_nil

    exporter = Mxrb::Exporter.new('unused.mpr', Dir.mktmpdir)
    source = exporter.send(
      :navigation_source,
      profiles: [{
        name: 'Native', home_page: nil, home_microflow: 'App.Dashboard',
        role_homes: [{ role: 'User', page: 'App.Home' }, { role: 'Guest' }],
        kind: 'Native', app_title: {}, items: []
      }]
    )
    expect(source).to include(
      'home_microflow: "App.Dashboard"', 'kind: "Native"',
      'home_for "User", page: "App.Home"'
    )
    design_source = exporter.send(
      :design_system_source,
      tokens: [], layouts: [], components: [], accessibility: [],
      themes: [
        { name: 'plain', inherits: nil, tokens: [{ kind: :spacing, name: 'unset', value: nil }] }
      ],
      contrast_pairs: [], forbid_literal_colors: false
    )
    expect(design_source).to include('theme "plain"', 'spacing :unset')
  end

  it 'rejects stale migrations and unsafe or corrupted asset manifests' do
    Dir.mktmpdir do |dir|
      theme = File.join(dir, 'theme')
      FileUtils.mkdir_p(theme)
      source = File.join(theme, 'tokens.scss')
      File.write(source, '$brand: #123456;')
      plan = Mxrb::Model::DesignSystem.new(dir)
                                      .plan_literal_migration('#123456' => 'var(--brand)')
      File.write(source, '$brand: #abcdef;')
      expect { plan.apply! }.to raise_error(Mxrb::SerializationError, /changed after preview/)

      [
        ['../escape.scss', Digest::SHA256.hexdigest('x'), /unsafe/],
        ['theme/missing.scss', Digest::SHA256.hexdigest('x'), /missing/],
        ['theme/tokens.scss', Digest::SHA256.hexdigest('wrong'), /checksum/]
      ].each_with_index do |(relative, checksum, message), index|
        manifest = File.join(dir, "manifest-#{index}.json")
        File.write(
          manifest,
          JSON.generate('files' => [{ 'path' => relative, 'sha256' => checksum }])
        )
        builder = Mxrb::Dsl::Builder.new(File.join(dir, "out-#{index}", 'app.mpr'))
        builder.project_assets(manifest, root: dir)
        expect { builder.build! }.to raise_error(Mxrb::SerializationError, message)
      end

      manifest = File.join(dir, 'same.json')
      File.write(
        manifest,
        JSON.generate(
          'files' => [{
            'path' => 'theme/tokens.scss',
            'sha256' => Digest::SHA256.file(source).hexdigest
          }]
        )
      )
      builder = Mxrb::Dsl::Builder.new(File.join(dir, 'same.mpr'))
      builder.project_assets(manifest, root: dir)
      expect { builder.build! }.not_to raise_error
    end
  end

  it 'rolls back every stylesheet when a multi-file migration fails' do
    Dir.mktmpdir do |dir|
      theme = File.join(dir, 'theme', 'web')
      FileUtils.mkdir_p(theme)
      first = File.join(theme, 'first.scss')
      second = File.join(theme, 'second.scss')
      File.write(first, '$first: #123456;')
      File.write(second, '$second: #123456;')
      plan = Mxrb::Model::DesignSystem.new(dir)
                                      .plan_literal_migration('#123456' => 'var(--brand)')
      expect(plan.rollback!).to equal(plan)
      moves = 0
      allow(FileUtils).to receive(:mv).and_wrap_original do |method, source, target|
        rollback = source.include?('rollback')
        moves += 1 unless rollback
        raise IOError, 'simulated replace failure' if !rollback && moves == 2

        method.call(source, target)
      end

      expect { plan.apply! }.to raise_error(IOError, /simulated replace failure/)
      expect(File.read(first)).to eq('$first: #123456;')
      expect(File.read(second)).to eq('$second: #123456;')
      expect(plan).not_to be_applied
      expect(Dir.glob(File.join(theme, '*.mxrb-*'))).to be_empty
    end
  end

  it 'composes asset and MPR plans with rollback across both stores' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.mpr')
      define_native_project(path)
      source = File.join(dir, 'theme', 'web', 'custom.scss')
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, '$legacy: #123456;')

      Mxrb.open(path, readonly: false) do |project|
        asset_plan = project.plan_design_token_migration('#123456' => 'var(--brand)')
        model_plan = project.plan_rename('App.Home', to: 'Landing')
        failing_plan = Object.new
        failing_plan.define_singleton_method(:apply!) { raise 'simulated batch failure' }
        failing_plan.define_singleton_method(:applied?) { false }

        batch = project.batch_plan([asset_plan, model_plan, failing_plan])
        expect { batch.apply! }.to raise_error(Mxrb::BatchError, /simulated batch failure/)

        expect(File.read(source)).to eq('$legacy: #123456;')
        expect(asset_plan).not_to be_applied
        expect(project.find_artifact('App.Home')).not_to be_nil
        expect(project.find_artifact('App.Landing')).to be_nil

        reversible = Object.new
        reversible.define_singleton_method(:apply!) { @applied = true }
        reversible.define_singleton_method(:applied?) { @applied == true }
        reversible.define_singleton_method(:rollback!) { raise 'simulated rollback failure' }
        failing_plan = Object.new
        failing_plan.define_singleton_method(:apply!) { raise 'second batch failure' }
        failing_plan.define_singleton_method(:applied?) { false }

        expect { project.batch_plan([reversible, failing_plan]).apply! }
          .to raise_error(Mxrb::BatchError, /rollback failed.*simulated rollback failure/)
      end
    end
  end

  it 'reports navigation and design-system integrity diagnostics' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'lint.mpr')
      Mxrb.define(path) do
        mendix_version '10.18.0'
        self.module(:App) do
          module_role :User
          page(:Home) { allowed_roles 'App.User' }
        end
        security { user_role :Known }
        navigation do
          profile :Duplicate
          profile :Duplicate, home_page: 'App.Home',
                              role_homes: { Missing: 'App.Home' } do
            home_for :Known, page: 'App.Home'
          end
        end
        design_system do
          color :foreground, value: '#777777'
          color :background, value: '#ffffff'
          theme(:dark) { color :accent, value: '#000000' }
          contrast foreground: :foreground, background: :background, level: :aaa
          contrast foreground: '#000000', background: '#ffffff'
          contrast foreground: 'red', background: '#fff'
          forbid_literal_colors
        end
      end
      theme = File.join(dir, 'theme')
      FileUtils.mkdir_p(theme)
      File.write(
        File.join(theme, 'tokens.scss'),
        ":root { --literal: #123456; --broken: var(--absent); }\n"
      )

      Mxrb.open(path) do |project|
        rules = project.analyze.diagnostics.map(&:rule)
        expect(rules).to include(
          :duplicate_navigation_profile,
          :navigation_profile_without_home,
          :unknown_navigation_role,
          :inaccessible_navigation_home,
          :unresolved_design_token,
          :insufficient_color_contrast,
          :invalid_contrast_color,
          :literal_design_color
        )
        analyzer = Mxrb::Semantic::Analyzer.new(project)
        details = analyzer.send(
          :navigation_diagnostics,
          navigation: {
            profiles: [{
              name: 'Array', home_microflow: 'App.Missing',
              role_homes: [{ role: 'Known', microflow: 'App.Missing' }]
            }]
          },
          security: { user_roles: [{ name: 'Known' }] }
        )
        expect(details.map(&:rule)).to include(:missing_navigation_target)
      end
    end
  end

  it 'renames projects without optional architecture metadata' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'plain.mpr')
      Mxrb.define(path) do
        mendix_version '10.18.0'
        self.module(:App) { page :Home }
      end
      Mxrb.open(path, readonly: false) do |project|
        project.query('DROP TABLE _MxrbArchitecture')
        plan = project.plan_rename('App.Home', to: 'Landing')
        expect(plan.architecture).to be_nil
        plan.apply!
        expect(project.find_artifact('App.Landing')).not_to be_nil
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
