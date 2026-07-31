# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Mxrb
  # Creates the minimum editable Ruby project accepted by `mxrb generate`.
  class Initializer
    Result = Data.define(:root, :files)
    NAME = /\A[A-Za-z][A-Za-z0-9_-]*\z/
    COMPOUND_SUFFIXES = %w[service clinic portal demo api app kit].freeze

    def initialize(name)
      @dir_name = name.to_s
      raise ArgumentError, 'project name must be snake_case or PascalCase' unless NAME.match?(@dir_name)

      @module_name = to_pascal_case(@dir_name)
      @mpr_name = "#{@module_name}.mpr"
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
      write(root, 'project.rb', project_rb)
      module_root = File.join(root, 'modules', @module_name)
      write(module_root, 'module.rb', module_rb)
      write(File.join(module_root, 'domain'), 'model.rb', model_rb)
    end

    def relative_files
      [
        'Gemfile', 'project.rb', File.join('modules', @module_name, 'module.rb'),
        File.join('modules', @module_name, 'domain', 'model.rb')
      ]
    end

    def to_pascal_case(value)
      parts = value.split(/[_-]+/)
      return parts.map { capitalize(_1) }.join if parts.length > 1
      return capitalize(value) unless value == value.downcase

      compound_parts(value).map { capitalize(_1) }.join
    end

    def compound_parts(value)
      suffix = COMPOUND_SUFFIXES.find { value.length > _1.length && value.end_with?(_1) }
      return [value] unless suffix

      [*compound_parts(value.delete_suffix(suffix)), suffix]
    end

    def capitalize(value)
      value[0].upcase + value[1..]
    end

    def write(directory, name, content)
      FileUtils.mkdir_p(directory)
      File.binwrite(File.join(directory, name), content)
    end

    def gemfile
      <<~RUBY
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "mxrb"
        # For local development against a cloned MXRB repository:
        # gem "mxrb", path: "../mxrb"
      RUBY
    end

    def project_rb
      <<~RUBY
        # frozen_string_literal: true

        require "mxrb"

        output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, "#{@mpr_name}"))

        Mxrb.define(output) do
          mendix_version "11.12.1"

          evaluate File.join(__dir__, "modules", "#{@module_name}", "module.rb")
        end
      RUBY
    end

    def module_rb
      <<~RUBY
        # frozen_string_literal: true

        self.module :#{@module_name} do
          evaluate File.join(__dir__, "domain", "model.rb")
        end
      RUBY
    end

    def model_rb
      <<~RUBY
        # frozen_string_literal: true

        # entity :Example do
        #   string :Name, required: true
        # end
      RUBY
    end
  end
end
