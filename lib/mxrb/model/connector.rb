# frozen_string_literal: true

module Mxrb
  module Model
    # A marketplace connector detected inside a project.
    #
    # MXRB never runs the connector; it only represents the public surface that
    # the semantic index can observe. Protected or non-decodable internals are
    # reported as unavailable (empty), never guessed.
    Connector = Data.define(
      :module_name, :protocol, :appstore_guid, :appstore_version,
      :entities, :microflows, :protected, :metadata
    ) do
      def known? = !protocol.nil?
    end
  end
end
