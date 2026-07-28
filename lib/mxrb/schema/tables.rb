# frozen_string_literal: true

module Mxrb
  module Schema
    # Known .mpr SQLite tables and their purpose.
    # Reverse-engineered from Mendix 9/10 projects + mxcli source inspection.
    # Columns marked (?) are inferred / version-dependent.
    TABLES = {
      "_MetaData" => {
        desc: "Single-row table with project-level metadata",
        columns: %w[MetaDataID MendixVersion ProjectID ProjectName],
      },
      "Unit" => {
        desc: "Every Mendix artefact (module, entity, page, microflow…) is a Unit",
        columns: %w[UnitID ContainerID ContainmentName UnitTypeID ContentsHash Contents],
      },
      "UnitType" => {
        desc: "Lookup table: numeric ID → qualified type name",
        columns: %w[UnitTypeID Name],
      },
      "PreferredHash" => {
        desc: "Stores preferred/last-known hash per unit for change detection",
        columns: %w[UnitID Hash],
      },
    }.freeze

    # Known UnitType names (qualified Mendix metamodel class names).
    # These appear in UnitType.Name and drive how Contents is decoded.
    UNIT_TYPES = %w[
      Mxmodels.Projects.Project
      Mxmodels.Projects.Module
      Mxmodels.DomainModels.DomainModel
      Mxmodels.DomainModels.Entity
      Mxmodels.DomainModels.Attribute
      Mxmodels.DomainModels.Association
      Mxmodels.Pages.Page
      Mxmodels.Pages.Layout
      Mxmodels.Pages.Snippet
      Mxmodels.Microflows.Microflow
      Mxmodels.Microflows.Nanoflow
      Mxmodels.Microflows.Rule
      Mxmodels.Settings.ProjectSettings
      Mxmodels.Settings.RuntimeSettings
      Mxmodels.Security.ProjectSecurity
      Mxmodels.Security.ModuleSecurity
      Mxmodels.Texts.SystemTextCollection
    ].freeze

    # Attribute types as used in the serialized Contents blob.
    ATTRIBUTE_TYPES = %w[
      AutoNumber Boolean Currency DateTime Decimal
      Enum Float HashString Integer Long String
    ].freeze
  end
end
