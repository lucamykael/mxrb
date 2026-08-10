# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Mxrb
  # Creates the minimum editable Ruby project accepted by `mxrb generate`.
  # rubocop:disable Metrics
  class Initializer
    Result = Data.define(:root, :files)
    NAME = /\A[A-Za-z][A-Za-z0-9_-]*\z/
    MODES = %i[mendix ruby].freeze
    COMPOUND_SUFFIXES = %w[service clinic portal demo api app kit].freeze

    attr_reader :mode

    def initialize(name, subject: :project, mxrb_path: nil, mode: :mendix, stack: nil)
      @dir_name = name.to_s
      raise ArgumentError, "#{subject} name must be snake_case or PascalCase" unless NAME.match?(@dir_name)

      @module_name = to_pascal_case(@dir_name)
      @mpr_name = "#{@module_name}.mpr"
      @mode = mode.to_sym
      raise ArgumentError, 'project mode must be mendix or ruby' unless MODES.include?(@mode)

      @stack = stack&.to_sym
      raise ArgumentError, 'Ruby stack presets require --mode ruby' if @stack && @mode != :ruby
      if @stack && !RubyApp::Preset::NAMES.include?(@stack)
        raise ArgumentError, "Ruby stack must be #{RubyApp::Preset::NAMES.join(' or ')}"
      end

      @mxrb_path = File.expand_path(mxrb_path) if mxrb_path
      raise ArgumentError, "mxrb path does not exist: #{@mxrb_path}" if @mxrb_path && !File.directory?(@mxrb_path)
    end

    def scaffold(into: Dir.pwd)
      parent = File.expand_path(into)
      root = File.join(parent, @dir_name)
      abort "#{root}: directory already exists" if File.exist?(root)

      FileUtils.mkdir_p(parent)
      staging = Dir.mktmpdir(".#{@dir_name}.mxrb-init-", parent)
      mode == :ruby ? write_ruby_scaffold(staging) : write_scaffold(staging)
      files = mode == :ruby ? generated_files(staging) : relative_files
      FileUtils.mv(staging, root)
      Result.new(root, files.map { File.join(root, _1) }.freeze)
    ensure
      FileUtils.rm_rf(staging) if staging && File.exist?(staging)
    end

    private

    def write_ruby_scaffold(root)
      bootstrap = File.join(root, '.mxrb-bootstrap')
      write_scaffold(bootstrap)
      target = File.join(bootstrap, @mpr_name)
      previous = ENV['MXRB_OUTPUT_PATH']
      library = @mxrb_path ? File.join(@mxrb_path, 'lib') : File.expand_path('..', __dir__)
      added_load_path = !$LOAD_PATH.include?(library)
      $LOAD_PATH.unshift(library) if added_load_path
      ENV['MXRB_OUTPUT_PATH'] = target
      load File.join(bootstrap, 'project.rb')
      Exporter.new(target, root, mode: :ruby).export!(parallel: false)
      pin_exported_gemfile(root) if @mxrb_path
      RubyApp::Preset.apply!(root, @stack) if @stack
    ensure
      if previous
        ENV['MXRB_OUTPUT_PATH'] = previous
      else
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      $LOAD_PATH.delete(library) if added_load_path
      FileUtils.rm_rf(bootstrap)
    end

    def generated_files(root)
      Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH)
         .select { File.file?(_1) }
         .map { Pathname.new(_1).relative_path_from(Pathname.new(root)).to_s }
         .sort
    end

    def pin_exported_gemfile(root)
      File.binwrite(
        File.join(root, 'Gemfile'),
        "# frozen_string_literal: true\n\nsource 'https://rubygems.org'\n" \
        "gem 'mxrb', path: #{@mxrb_path.inspect}\n"
      )
    end

    def write_scaffold(root)
      write(root, 'Gemfile', gemfile)
      write(root, '.gitignore', gitignore)
      write(root, '.env.example', env_example)
      environment_names.each do |name|
        write(File.join(root, 'config', 'environments'), "#{name}.env.example", environment_example(name))
      end
      write(root, 'project.rb', project_rb)
      write(File.join(root, 'app', 'navigation', 'responsive'), '.keep', '')
      write_design_scaffold(root)
      module_root = File.join(root, 'modules', @module_name)
      write_module_scaffold(module_root)
    end

    def write_design_scaffold(root)
      design_files.each do |parts, template|
        write(File.join(root, *parts[0...-1]), parts.last, Scaffold::Templates.render(template))
      end
    end

    def design_files
      {
        %w[app design_system design_system.rb] => :design_system,
        %w[theme web custom-variables.scss] => :theme_custom_variables,
        %w[theme web main.scss] => :theme_main,
        %w[theme web exclusion-variables.scss] => :theme_exclusion_variables,
        %w[theme web settings.json] => :theme_settings,
        %w[theme-cache web theme.compiled.css] => :theme_compiled
      }
    end

    def write_module_scaffold(module_root)
      write(module_root, 'module.rb', module_rb)
      write(File.join(module_root, 'domain'), 'model.rb', model_rb)
      write(File.join(module_root, 'application'), 'application.rb', application_rb)
      write(File.join(module_root, 'domain', 'entities'), '.keep', '')
      write(File.join(module_root, 'presentation'), 'presentation.rb', presentation_rb)
      write(File.join(module_root, 'presentation', 'pages'), 'home.rb', home_rb)
    end

    def relative_files
      module_prefix = File.join('modules', @module_name)
      ['Gemfile', '.gitignore', '.env.example', 'project.rb',
       *relative_module_files.map { File.join(module_prefix, _1) },
       File.join('app', 'navigation', 'responsive', '.keep'),
       *design_files.keys.map { File.join(*_1) },
       *environment_names.map { File.join('config', 'environments', "#{_1}.env.example") }]
    end

    def relative_module_files
      [
        'module.rb', File.join('domain', 'model.rb'),
        File.join('application', 'application.rb'), File.join('domain', 'entities', '.keep'),
        File.join('presentation', 'presentation.rb'), File.join('presentation', 'pages', 'home.rb')
      ]
    end

    def to_pascal_case(value)
      parts = value.split(/[_-]+/)
      return parts.map { capitalize(_1) }.join if parts.length > 1
      return capitalize(value) unless value == value.downcase

      stem = value.sub(/\d+\z/, '')
      digits = value.delete_prefix(stem)
      compound_parts(stem).map { capitalize(_1) }.join + digits
    end

    def compound_parts(value)
      suffix = COMPOUND_SUFFIXES.find { value.length > _1.length && value.end_with?(_1) }
      return [value] unless suffix

      [*compound_parts(value.delete_suffix(suffix)), suffix]
    end

    def capitalize(value) = value[0].upcase + value[1..]

    def write(directory, name, content)
      FileUtils.mkdir_p(directory)
      File.binwrite(File.join(directory, name), content)
    end

    def gemfile
      <<~RUBY
        # frozen_string_literal: true

        source "https://rubygems.org"

        #{gem_declaration}
      RUBY
    end

    def gitignore
      <<~TEXT
        # Local environment and secrets. Commit only .env.example with blank values.
        .env
        .env.*
        !.env.example
        config/environments/*.env
        !config/environments/*.env.example
      TEXT
    end

    def env_example
      <<~TEXT
        # Copy to .env and keep real values local. Never commit secrets.
        MXRB_MENDIX_PAT=
      TEXT
    end

    def environment_names = %w[development qa staging production]

    def environment_example(name)
      <<~TEXT
        # Copy to #{name}.env. Process ENV still has highest precedence.
        MXRB_DATABASE_PATH=.mxrb/runtime/#{name}.sqlite3
        MXRB_SESSION_TTL=3600
        MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=false
        MXRB_AUTH_TOKENS=
        MXRB_USERS_JSON=
      TEXT
    end

    def gem_declaration
      return 'gem "mxrb"' unless @mxrb_path

      %(gem "mxrb", path: #{@mxrb_path.inspect})
    end

    def project_rb
      <<~RUBY
        # frozen_string_literal: true

        require "mxrb"

        Mxrb::Environment.load(root: __dir__).apply

        output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, "#{@mpr_name}"))

        Mxrb.define(output) do
          mendix_version "11.12.1"

          navigation do
            profile :Responsive,
                    home_page: "#{@module_name}.Home",
                    app_title: "#{@module_name}" do
              evaluate_dir File.join(__dir__, "app", "navigation", "responsive")
            end
          end

          evaluate File.join(__dir__, "app", "design_system", "design_system.rb")
          evaluate File.join(__dir__, "modules", "#{@module_name}", "module.rb")
        end
      RUBY
    end

    def module_rb
      <<~RUBY
        # frozen_string_literal: true

        self.module :#{@module_name} do
          evaluate File.join(__dir__, "domain", "model.rb")
          evaluate File.join(__dir__, "application", "application.rb")
          evaluate File.join(__dir__, "presentation", "presentation.rb")
        end
      RUBY
    end

    def model_rb
      <<~RUBY
        # frozen_string_literal: true

        evaluate_dir File.join(__dir__, "enumerations")
        evaluate_dir File.join(__dir__, "entities")
      RUBY
    end

    def application_rb
      <<~RUBY
        # frozen_string_literal: true

        evaluate_dir File.join(__dir__, "use_cases")
        evaluate_dir File.join(__dir__, "validations")
        evaluate_dir File.join(__dir__, "queries")
      RUBY
    end

    def presentation_rb
      <<~RUBY
        # frozen_string_literal: true

        layout :ApplicationLayout, title: "#{@module_name}"

        evaluate_dir File.join(__dir__, "pages")
        evaluate_dir File.join(__dir__, "snippets")
        evaluate_dir File.join(__dir__, "client_actions")
      RUBY
    end

    def home_rb
      <<~RUBY
        # frozen_string_literal: true

        page :Home do
          title "#{@module_name}"
          layout "#{@module_name}.ApplicationLayout"

          container :pageHeader, class_name: "mxrb-page-header" do
            text :pageTitle, caption: "#{@module_name}"
            text :pageSubtitle,
                 caption: "A Ruby-first Mendix application, ready to grow."
          end

          container :dashboard, class_name: "mxrb-dashboard-grid" do
            container :domainCard, class_name: "mxrb-card" do
              text :domainEyebrow, caption: "DOMAIN"
              text :domainTitle, caption: "Model your business"
              text :domainCopy, caption: "Add entities, enumerations and associations using the mxrb DSL."
            end

            container :logicCard, class_name: "mxrb-card" do
              text :logicEyebrow, caption: "LOGIC"
              text :logicTitle, caption: "Build application flows"
              text :logicCopy, caption: "Keep use cases, validations and queries organized by convention."
            end

            container :experienceCard, class_name: "mxrb-card" do
              text :experienceEyebrow, caption: "EXPERIENCE"
              text :experienceTitle, caption: "Ship a polished UI"
              text :experienceCopy, caption: "Create pages, snippets and client actions without manual wiring."
            end
          end
        end
      RUBY
    end
  end
  # rubocop:enable Metrics
end
