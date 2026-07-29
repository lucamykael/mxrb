# frozen_string_literal: true

module Mxrb
  Error              = Class.new(StandardError)
  NotMprError        = Class.new(Error)
  UnsupportedVersion = Class.new(Error)
  SchemaError        = Class.new(Error)
  ReadOnlyError      = Class.new(Error)
  SerializationError = Class.new(Error)
  ValidationError    = Class.new(Error)
  FunctionalTestError = Class.new(Error)
  ToolchainError      = Class.new(Error)
end
