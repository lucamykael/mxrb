# frozen_string_literal: true

require_relative "mxrb/version"
require_relative "mxrb/errors"
require_relative "mxrb/schema/tables"
require_relative "mxrb/io/mpr_file"
require_relative "mxrb/model/project"
require_relative "mxrb/model/unit"
require_relative "mxrb/model/module"
require_relative "mxrb/model/entity"
require_relative "mxrb/model/attribute"
require_relative "mxrb/model/association"
require_relative "mxrb/model/page"
require_relative "mxrb/model/microflow"
require_relative "mxrb/dsl/builder"

module Mxrb
  # Open an existing .mpr file for reading/writing.
  #
  #   Mxrb.open("MyApp.mpr") { |p| puts p.modules.map(&:name) }
  #
  def self.open(path, &block)
    project = Model::Project.open(path)
    return project unless block

    begin
      block.call(project)
    ensure
      project.close
    end
  end

  # Define a new project via the Ruby DSL and write it to disk.
  #
  #   Mxrb.define("MyApp.mpr") do
  #     mendix_version "10.18.0"
  #     module :MyModule do
  #       entity :Customer do
  #         string  :Name, required: true
  #         integer :Age
  #       end
  #     end
  #   end
  #
  def self.define(path, &block)
    Dsl::Builder.new(path).tap { _1.instance_eval(&block) }.build!
  end
end
