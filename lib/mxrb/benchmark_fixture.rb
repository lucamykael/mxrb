# frozen_string_literal: true

require 'fileutils'

module Mxrb
  # Copies a benchmark MPR into an isolated mutable workspace. Mendix v2
  # projects keep unit payloads in a required sibling mprcontents directory.
  module BenchmarkFixture
    module_function

    def copy(source, directory)
      destination = File.join(directory, File.basename(source))
      FileUtils.cp(source, destination)
      contents = File.join(File.dirname(source), 'mprcontents')
      FileUtils.cp_r(contents, File.join(directory, 'mprcontents')) if File.directory?(contents)
      destination
    end
  end
end
