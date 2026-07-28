# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "mxrb"
  s.version     = "0.1.0"
  s.summary     = "Pure-Ruby read/write engine for Mendix .mpr projects — no mxcli required"
  s.description = "mxrb reads and writes Mendix .mpr files (SQLite3) directly, providing a Ruby DSL to define entities, pages, microflows and modules without any dependency on the official mxcli tooling."
  s.authors     = ["Lucas Moura"]
  s.license     = "MIT"

  s.required_ruby_version = ">= 4.0"

  s.files = Dir["lib/**/*.rb", "bin/*", "README.md"]
  s.executables = ["mxrb"]
  s.require_paths = ["lib"]

  s.add_dependency "sqlite3", "~> 2.0"
  s.add_dependency "bson",    "~> 5.2"
  s.add_dependency "base64",     "~> 0.2"
  s.add_dependency "bigdecimal", "~> 3.1"

  s.add_development_dependency "rspec",   "~> 3.13"
  s.add_development_dependency "rubocop", "~> 1.65"
end
