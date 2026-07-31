# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Mxrb
  # Creates the minimum editable Ruby project accepted by `mxrb generate`.
  # rubocop:disable Metrics/ClassLength
  class Initializer
    Result = Data.define(:root, :files)
    NAME = /\A[A-Za-z][A-Za-z0-9_-]*\z/
    COMPOUND_SUFFIXES = %w[service clinic portal demo api app kit].freeze

    def initialize(name, subject: :project, mxrb_path: nil)
      @dir_name = name.to_s
      raise ArgumentError, "#{subject} name must be snake_case or PascalCase" unless NAME.match?(@dir_name)

      @module_name = to_pascal_case(@dir_name)
      @mpr_name = "#{@module_name}.mpr"
      @mxrb_path = File.expand_path(mxrb_path) if mxrb_path
      raise ArgumentError, "mxrb path does not exist: #{@mxrb_path}" if @mxrb_path && !File.directory?(@mxrb_path)
    end

    def scaffold(into: Dir.pwd)
      parent = File.expand_path(into)
      root = File.join(parent, @dir_name)
      abort "#{root}: directory already exists" if File.exist?(root)

      FileUtils.mkdir_p(parent)
      staging = Dir.mktmpdir(".#{@dir_name}.mxrb-init-", parent)
      write_scaffold(staging)
      FileUtils.mv(staging, root)
      Result.new(root, relative_files.map { File.join(root, _1) }.freeze)
    ensure
      FileUtils.rm_rf(staging) if staging && File.exist?(staging)
    end

    private

    def write_scaffold(root)
      write(root, 'Gemfile', gemfile)
      write(root, '.gitignore', gitignore)
      write(root, '.env.example', env_example)
      write(root, 'project.rb', project_rb)
      module_root = File.join(root, 'modules', @module_name)
      write_module_scaffold(module_root)
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
       *relative_module_files.map { File.join(module_prefix, _1) }]
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
        gem "dotenv", "~> 3.0"
      RUBY
    end

    def gitignore
      <<~TEXT
        # Local environment and secrets. Commit only .env.example with blank values.
        .env
        .env.*
        !.env.example
      TEXT
    end

    def env_example
      <<~TEXT
        # Copy to .env and keep real values local. Never commit secrets.
        MXRB_MENDIX_PAT=
      TEXT
    end

    def gem_declaration
      return 'gem "mxrb"' unless @mxrb_path

      %(gem "mxrb", path: #{@mxrb_path.inspect})
    end

    def project_rb
      <<~RUBY
        # frozen_string_literal: true

        require "dotenv/load"
        require "mxrb"

        output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, "#{@mpr_name}"))

        Mxrb.define(output) do
          mendix_version "11.12.1"

          navigation do
            profile :Responsive,
                    home_page: "#{@module_name}.Home",
                    app_title: "#{@module_name}"
          end

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

        layout :ApplicationLayout

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
          end
        end
      RUBY
    end
  end
  # rubocop:enable Metrics/ClassLength
end
