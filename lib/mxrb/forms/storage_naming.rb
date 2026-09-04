# frozen_string_literal: true

require_relative 'catalog'

module Mxrb
  module Forms
    StorageProperty = Data.define(:schema_property, :name, :evidence) do
      def observed? = evidence == :studio_observation
    end

    # Maps editor-schema names to v11 MPR field names. Exceptional names are
    # explicit and evidence-backed; the rest follow Mendix PascalCase storage.
    module StorageNaming
      TYPE_ALIASES = {
        'DivContainer' => 'DivContainer',
        'DropDownButton' => 'MobileDropDownButton',
        'DynamicImageViewer' => 'ImageViewer',
        'GridColumn' => 'DataGridColumn',
        'LayoutCallArgument' => 'FormCallArgument',
        'MicroflowClientAction' => 'MicroflowAction',
        'NoClientAction' => 'NoAction',
        'PageClientAction' => 'FormAction',
        'PageSettings' => 'FormSettings',
        'SelectButton' => 'DataGridSelectButton',
        'TableCell' => 'DbTableCell',
        'TabContainer' => 'TabControl'
      }.freeze
      private_constant :TYPE_ALIASES

      LEGACY_TYPE_ALIASES = {
        'FormForSpecialization' => 'PageForSpecialization',
        'NewGridDatabaseSource' => 'GridXPathSource',
        'NewListViewDatabaseSource' => 'ListViewXPathSource',
        'NewSelectorDatabaseSource' => 'SelectorXPathSource'
      }.freeze
      private_constant :LEGACY_TYPE_ALIASES

      ALIASES = {
        %w[AssociationWidget selectPageSettings] => 'PopupFormSettings',
        %w[AttributeWidgetWithPlaceholder placeholderTemplate] => 'Placeholder',
        %w[Button caption] => 'CaptionTemplate',
        %w[ControlBar items] => 'NewButtons',
        %w[ControlBarButton caption] => 'CaptionTemplate',
        %w[DataGrid caption] => 'CaptionTemplate',
        %w[ColumnGrid tooltipPage] => 'TooltipForm',
        %w[DropDownSearchField allowMultipleSelect] => 'AllowMultiSelect',
        %w[GridControlBar defaultButton] => 'DefaultButtonPointer',
        %w[GridColumn width] => 'WidthValue',
        %w[GridNewButton pageSettings] => 'FormSettings',
        %w[DataGridAddButton pageSettings] => 'FormSettings',
        %w[GridSortItem sortDirection] => 'SortOrder',
        %w[GroupBox caption] => 'CaptionTemplate',
        %w[LayoutCall layout] => 'Form',
        %w[ListViewTemplate specialization] => 'Entity',
        %w[Page allowedRoles] => 'AllowedModuleRoles',
        %w[Page layoutCall] => 'FormCall',
        %w[PageClientAction pageSettings] => 'FormSettings',
        %w[PageSettings page] => 'Form',
        %w[PageForSpecialization pageSettings] => 'FormSettings',
        %w[ReferenceSelector gotoPageSettings] => 'GotoFormSettings',
        %w[ReferenceSetSelector xPathConstraint] => 'SelectableXPathConstraint',
        %w[ScrollContainer center] => 'CenterRegion',
        %w[SnippetCall snippet] => 'Form',
        %w[SnippetCallWidget snippetCall] => 'FormCall',
        %w[Table columns] => 'ColumnWidths',
        %w[TableColumn width] => 'Value',
        %w[TabContainer defaultPage] => 'DefaultPagePointer'
      }.transform_keys(&:freeze).freeze
      private_constant :ALIASES

      LEGACY_ALIASES = {
        %w[DataView editability] => 'Editable',
        %w[GridXPathSource xPathConstraint] => 'DatabaseConstraints',
        %w[SelectorXPathSource xPathConstraint] => 'DatabaseConstraints',
        %w[XPathSourceBase xPathConstraint] => 'DatabaseConstraints'
      }.transform_keys(&:freeze).freeze
      private_constant :LEGACY_ALIASES

      module_function

      def resolve(property)
        alias_name = ALIASES[[property.declared_by, property.name]]
        if alias_name
          StorageProperty.new(property, alias_name, :studio_observation)
        else
          StorageProperty.new(property, pascal_case(property.name), :schema_convention)
        end
      end

      def candidates(property)
        [
          resolve(property).name,
          LEGACY_ALIASES[[property.declared_by, property.name]],
          pascal_case(property.name)
        ].compact.uniq.freeze
      end

      def pascal_case(name)
        name.to_s.sub(/\A./, &:upcase).freeze
      end

      def storage_type_name(schema_name)
        TYPE_ALIASES.fetch(schema_name.to_s, schema_name.to_s)
      end

      def schema_type_name(storage_name)
        LEGACY_TYPE_ALIASES.fetch(storage_name.to_s) do
          TYPE_ALIASES.key(storage_name.to_s) || storage_name.to_s
        end
      end
    end
  end
end
