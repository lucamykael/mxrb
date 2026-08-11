# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Pages$Page / Forms$Page
    # ContainmentName: "Documents"
    class Page < Unit
      attr_reader :name, :documentation, :url, :layout_id, :title,
                  :popup_width, :popup_height, :popup_resizable, :excluded,
                  :allowed_module_roles, :parameters, :export_level,
                  :widgets, :data_source, :appearance_class, :appearance_style,
                  :raw_document

      def decode(doc)
        @raw_document        = doc
        @storage_type        = doc["$Type"] || "Forms$Page"
        @name                = doc["Name"] || doc["name"]
        @documentation       = doc["Documentation"] || doc["documentation"] || ""
        @url                 = doc["Url"] || doc["URL"] || doc["url"] || ""
        @title               = extract_text(doc["Title"] || doc["title"])
        @layout_id           = extract_layout(doc)
        @popup_width         = doc["PopupWidth"] || 0
        @popup_height        = doc["PopupHeight"] || 0
        @popup_resizable     = doc["PopupResizable"] == true
        @excluded            = doc["Excluded"] == true
        @export_level        = doc["ExportLevel"] || "Hidden"
        @appearance_class    = doc.dig("Appearance", "Class").to_s
        @appearance_style    = doc.dig("Appearance", "Style").to_s
        @allowed_module_roles = parse_array(doc["AllowedModuleRoles"] || doc["AllowedRoles"] || doc["allowedModuleRoles"])
        @parameters          = parse_array(doc["Parameters"] || doc["parameters"])
        @widgets             = []
        parse_widgets(widget_roots(doc))
      end

      def to_bson
        {
          "$ID"                => @id,
          "$Type"              => @storage_type,
          "Name"               => @name,
          "Documentation"      => @documentation || "",
          "Url"                => @url || "",
          "Title"              => serialize_title,
          "Layout"             => @layout_id,
          "MarkAsUsed"         => false,
          "Excluded"           => @excluded || false,
          "AllowedModuleRoles" => IO::BsonCodec.build_array(@allowed_module_roles || [], marker: 1),
          "Parameters"         => IO::BsonCodec.build_array(@parameters || []),
          "PopupWidth"         => @popup_width || 0,
          "PopupHeight"        => @popup_height || 0,
          "PopupResizable"     => @popup_resizable || false,
          "ExportLevel"        => @export_level || "Hidden",
        }
      end

      def inspect
        "#<Mxrb::Page name=#{@name.inspect} layout=#{@layout_id.to_s.slice(0, 8)}>"
      end

      private

      def extract_text(obj)
        return obj if obj.is_a?(String)
        return "" unless obj.is_a?(Hash)
        return extract_text(obj["Template"]) if obj["$Type"] == "Forms$ClientTemplate"

        translations = parse_array(obj["Translations"] || obj["Items"] || obj["translations"] || [])
        translation = translations.first
        return "" unless translation.is_a?(Hash)

        translation["Translation"] || translation["Text"] || translation["text"] || ""
      end

      def extract_layout(doc)
        return doc.dig("FormCall", "Form") if doc.dig("FormCall", "Form")

        IO::BsonCodec.extract_id(doc["Layout"] || doc["LayoutId"])
      end

      def serialize_title
        { "$ID" => SecureRandom.uuid, "$Type" => "Texts$Text", "Translations" => [1] }
      end

      def parse_widgets(items, target = @widgets)
        items.each do |widget|
          next unless widget.is_a?(Hash)
          type = widget["$Type"]
          if %w[Pages$DataView Forms$DataView].include?(type)
            @data_source = parse_source(widget["DataSource"])
            parse_widgets(child_widgets(widget), target)
            next
          end
          if type == "CustomWidgets$CustomWidget"
            target << pluggable_widget(widget)
            next
          end
          if %w[Pages$DataGrid Forms$DataGrid].include?(type)
            target << data_grid_widget(widget)
            next
          end
          if %w[Pages$TabControl Forms$TabControl].include?(type)
            target << tab_control_widget(widget)
            next
          end
          if %w[Pages$SnippetCall Forms$SnippetCall Forms$SnippetCallWidget].include?(type)
            snippet_ref = (
              widget.dig("SnippetSettings", "Snippet") || widget.dig("FormCall", "Form")
            ).to_s
            target << { type: :snippet, name: widget["Name"] || "snippet",
                        options: { snippet: snippet_ref }, events: [] }
            next
          end
          if %w[Pages$Container Forms$Container Forms$DivContainer].include?(type)
            children = []
            parse_widgets(parse_array(widget["Widgets"]), children)
            target << { type: :container, name: widget["Name"] || "container",
                        options: container_options(widget), children: children,
                        events: container_events(widget) }
            next
          end
          if layout_container?(widget)
            parse_widgets(child_widgets(widget), target)
            parse_form_call_arguments(widget["Arguments"], target)
            next
          end
          unless supported_widget?(type)
            target << native_widget(widget)
            next
          end

          events = {
            "OnChangeAction" => :on_change,
            "OnEnterAction" => :on_enter,
            "OnLeaveAction" => :on_leave,
            "Action" => :on_click
          }.filter_map do |property, event|
            action = parse_action(widget[property])
            action&.merge(event: event)
          end
          widget_type = widget_type(type)
          target << {
            type: widget_type,
            name: widget["Name"],
            options: widget_options(widget, widget_type),
            events: events
          }
        end
      end

      def supported_widget?(type)
        widget_type(type)
      end

      def widget_type(type)
        case type
        when "Pages$ActionButton", "Forms$ActionButton", "Forms$GridActionButton"
          :button
        when "Pages$TextBox", "Forms$TextBox"
          :text_box
        when "Pages$TextArea", "Forms$TextArea"
          :text_area
        when "Pages$CheckBox", "Forms$CheckBox"
          :check_box
        when "Pages$DatePicker", "Forms$DatePicker"
          :date_picker
        when "Pages$ReferenceSelector", "Forms$ReferenceSelector",
             "Pages$InputReferenceSetSelector", "Forms$InputReferenceSetSelector"
          :reference_selector
        when "Pages$DynamicText", "Forms$DynamicText", "Pages$Label", "Forms$Label"
          :text
        when "Pages$DropDownWidget", "Forms$DropDownWidget", "Forms$DropDown"
          :drop_down
        end
      end

      def widget_options(widget, widget_type)
        options = appearance_options(widget).merge(
          attribute: attribute_path(widget),
          caption: widget_caption(widget, widget_type)
        ).compact
        parameters = template_parameters(widget)
        options[:parameters] = parameters unless parameters.empty?
        options[:lines] = widget["NumberOfLines"] if widget_type == :text_area && widget["NumberOfLines"]
        options
      end

      def container_options(widget)
        appearance_options(widget)
      end

      def appearance_options(widget)
        class_name = widget.dig("Appearance", "Class") || widget["Class"]
        style = widget.dig("Appearance", "Style") || widget["Style"]
        dynamic = widget.dig("Appearance", "DynamicClasses")
        visibility = widget.dig("ConditionalVisibilitySettings", "Expression")
        { class: class_name.to_s, style: style.to_s,
          dynamic_class: dynamic.to_s, visible: visibility.to_s }.reject { |_key, value| value.empty? }
      end

      def container_events(widget)
        action = parse_action(widget["OnClickAction"] || widget["Action"])
        action ? [action.merge(event: :on_click)] : []
      end

      def template_parameters(widget)
        template = widget["Content"] || widget["CaptionTemplate"] || widget["LabelTemplate"]
        parse_array(template.is_a?(Hash) ? template["Parameters"] : nil).filter_map do |parameter|
          expression = parameter["Expression"].to_s
          attribute = parameter.dig("AttributeRef", "Attribute").to_s.split('.').last.to_s
          expression = "$currentObject/#{attribute}" if expression.empty? && !attribute.empty?
          expression unless expression.empty?
        end
      end

      def attribute_path(widget)
        widget["AttributePath"] || widget.dig("AttributeRef", "Attribute")
      end

      def widget_caption(widget, widget_type)
        return extract_text(widget["Content"] || widget["Text"] || widget["LabelText"]) if widget_type == :text

        extract_text(
          widget["Caption"] ||
          widget["LabelText"] ||
          widget["LabelTemplate"] ||
          widget.dig("CaptionTemplate", "Template")
        )
      end

      def data_grid_widget(widget)
        columns = parse_array(widget["Columns"]).map do |column|
          {
            name: column["Name"],
            attribute: attribute_path(column),
            caption: extract_text(column["Caption"])
          }.compact
        end
        options = { entity: grid_entity(widget), columns: columns }.compact
        options[:search_bar] = parse_search_bar(widget["SearchBar"]) if widget["SearchBar"].is_a?(Hash)
        options[:toolbar]    = parse_toolbar(widget["ToolBar"])       if widget["ToolBar"].is_a?(Hash)
        { type: :data_grid, name: widget["Name"], options: options, events: grid_events(widget) }
      end

      def pluggable_widget(widget)
        widget_id = widget.dig("Type", "WidgetId").to_s
        return native_widget(widget) if widget_id.empty?

        case widget_id
        when "com.mendix.widget.web.datagrid.Datagrid" then data_grid2_widget(widget)
        when "com.mendix.widget.web.combobox.Combobox"  then combo_box_widget(widget)
        when "com.mendix.widget.web.gallery.Gallery"    then gallery_widget(widget)
        else generic_pluggable_widget(widget)
        end
      end

      def generic_pluggable_widget(widget)
        object_type = widget.dig("Type", "ObjectType")
        properties = pluggable_properties(widget["Object"], object_type)
        children = nested_pluggable_widgets(properties)
        properties = strip_pluggable_widgets(properties)
        options = appearance_options(widget).merge(
          widget_id: widget.dig("Type", "WidgetId"),
          widget_name: widget.dig("Type", "WidgetName"),
          platform: widget.dig("Type", "SupportedPlatform"),
          properties:
        ).compact
        {
          type: :pluggable_widget, name: widget["Name"] || "widget",
          options:, children:, events: pluggable_events(properties)
        }
      end

      def pluggable_properties(object, object_type)
        return {} unless object.is_a?(Hash) && object_type.is_a?(Hash)

        types = parse_array(object_type["PropertyTypes"])
        types_by_id = types.to_h { [IO::BsonCodec.extract_id(_1["$ID"]), _1] }
        parse_array(object["Properties"]).each_with_object({}) do |property, result|
          type = types_by_id[IO::BsonCodec.extract_id(property["TypePointer"])]
          next unless type

          result[type["PropertyKey"].to_s] = pluggable_value(
            property["Value"], type["ValueType"]
          )
        end
      end

      def pluggable_value(value, value_type)
        return nil unless value.is_a?(Hash)

        type = value_type.is_a?(Hash) ? value_type["Type"].to_s : ""
        widgets = parse_array(value["Widgets"])
        unless widgets.empty?
          parsed = []
          parse_widgets(widgets, parsed)
          return { widgets: parsed }
        end
        objects = parse_array(value["Objects"])
        unless objects.empty?
          object_type = value_type.is_a?(Hash) ? value_type["ObjectType"] : nil
          return { objects: objects.map { pluggable_properties(_1, object_type) } }
        end

        return extract_text(value["TextTemplate"]) if value["TextTemplate"].is_a?(Hash)
        return value.dig("AttributeRef", "Attribute") if value["AttributeRef"].is_a?(Hash)
        return pluggable_data_source(value["DataSource"]) if value["DataSource"].is_a?(Hash)
        return value["Expression"] unless value["Expression"].to_s.empty?
        return value["Image"] unless value["Image"].to_s.empty?
        return value["Form"] unless value["Form"].to_s.empty?

        primitive = value["PrimitiveValue"]
        return primitive == true || primitive.to_s.casecmp("true").zero? if type == "Boolean"
        return primitive.to_i if type == "Integer"
        return primitive.to_f if %w[Decimal Number].include?(type)
        return primitive unless primitive.nil? || primitive.to_s.empty?

        action = value["Action"]
        return pluggable_action(action) if action.is_a?(Hash) && action["$Type"] != "Forms$NoAction"
        return value["Selection"] unless value["Selection"].to_s.empty? || value["Selection"] == "None"

        nil
      end

      def pluggable_data_source(source)
        {
          data_source: source.dig("EntityRef", "Entity") || source["Entity"],
          xpath: source["XPathConstraint"].to_s,
          sort: parse_array(source.dig("SortBar", "SortItems")).map do |item|
            {
              attribute: item.dig("AttributeRef", "Attribute"),
              direction: item["SortDirection"].to_s
            }.compact
          end
        }.compact
      end

      def pluggable_action(action)
        candidates = {
          "nanoflow" => action["Nanoflow"],
          "microflow" => action["Microflow"],
          "page" => action["Form"]
        }
        kind, handler = candidates.find { |_candidate, value| !value.to_s.empty? }
        kind ||= "action"
        handler ||= action["$Type"]
        { kind:, handler: handler.to_s }
      end

      def nested_pluggable_widgets(value, found = [])
        case value
        when Hash
          widgets = value[:widgets] || value["widgets"]
          found.concat(Array(widgets)) if widgets
          value.each_value { nested_pluggable_widgets(_1, found) }
        when Array then value.each { nested_pluggable_widgets(_1, found) }
        end
        found.uniq { [_1[:name] || _1["name"], _1[:type] || _1["type"]] }
      end

      def strip_pluggable_widgets(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if key.to_s == "widgets"

            result[key] = strip_pluggable_widgets(child)
          end
        when Array then value.map { strip_pluggable_widgets(_1) }
        else value
        end
      end

      def pluggable_events(properties)
        properties.filter_map do |key, value|
          next unless value.is_a?(Hash) && value[:handler]

          event = key.to_s.match?(/change/i) ? :on_change : :on_click
          value.merge(event:)
        end
      end

      def gallery_widget(widget)
        properties = custom_property_map(widget["Object"], widget.dig("Type", "ObjectType"))
        source = properties.dig("datasource", "DataSource") || {}
        children = []
        parse_widgets(parse_array(properties.dig("content", "Widgets")), children)
        sort = parse_array(source.dig("SortBar", "SortItems")).map do |item|
          {
            attribute: item.dig("AttributeRef", "Attribute"),
            direction: item["SortDirection"].to_s
          }.compact
        end
        xpath = source["XPathConstraint"].to_s
        options = appearance_options(widget).merge(
          entity: source.dig("EntityRef", "Entity"), xpath: xpath,
          association: xpath[/\[([\w.]+)\s*=\s*\$\w+\]/, 1],
          context_variable: xpath[/\$([A-Za-z_]\w*)/, 1], sort: sort
        ).compact
        {
          type: :gallery, name: widget["Name"], options: options,
          children: children, events: []
        }
      end

      def native_widget(widget)
        deep = widget.reject { |key, _| %w[$ID $Type Name].include?(key.to_s) }
        widget_id = widget.dig("Type", "WidgetId").to_s
        platform = widget.dig("Type", "SupportedPlatform").to_s
        options = { native_type: widget["$Type"], deep_structure: deep }
        options[:widget_id] = widget_id unless widget_id.empty?
        options[:platform] = platform unless platform.empty?
        {
          type: :native_widget, name: widget["Name"] || "widget",
          options:, events: []
        }
      end

      def data_grid2_widget(widget)
        properties = custom_property_map(widget["Object"], widget.dig("Type", "ObjectType"))
        return data_grid_widget(widget) if properties.empty? && widget["DataSource"]

        entity = properties.dig("datasource", "DataSource", "EntityRef", "Entity")
        column_type = custom_property_type(widget.dig("Type", "ObjectType"), "columns")
                      &.dig("ValueType", "ObjectType")
        columns = parse_array(properties.dig("columns", "Objects")).map do |object|
          values = custom_property_map(object, column_type)
          {
            name: extract_text(values.dig("header", "TextTemplate")),
            attribute: values.dig("attribute", "AttributeRef", "Attribute"),
            caption: extract_text(values.dig("header", "TextTemplate"))
          }.compact
        end
        {
          type: :data_grid, name: widget["Name"],
          options: { entity: entity, columns: columns }.compact, events: grid_events(widget)
        }
      end

      def grid_events(widget)
        {
          "OnChangeAction" => :on_change,
          "OnClickAction" => :on_click,
          "Action" => :on_click
        }.filter_map do |property, event|
          action = parse_action(widget[property])
          action&.merge(event: event)
        end
      end

      def combo_box_widget(widget)
        properties = custom_property_map(widget["Object"], widget.dig("Type", "ObjectType"))
        if properties.empty? && widget["AttributePath"]
          reference = widget["SelectorType"] == "Reference"
          options = {
            attribute: widget["AttributePath"], caption: extract_text(widget["LabelText"]),
            display_attribute: widget["DisplayAttribute"]
          }.compact
          return {
            type: reference ? :reference_selector : :drop_down,
            name: widget["Name"], options: options, events: grid_events(widget)
          }
        end

        association = parse_array(properties.dig("attributeAssociation", "EntityRef", "Steps"))
                      .first&.fetch("Association", nil)
        reference = properties.dig("optionsSourceType", "PrimitiveValue") == "association"
        attribute = if reference
          association
        else
          properties.dig("attributeEnumeration", "AttributeRef", "Attribute")
        end
        options = {
          attribute: attribute, caption: extract_text(widget["LabelTemplate"])
        }.compact
        if reference
          options[:display_attribute] = properties.dig(
            "optionsSourceAssociationCaptionAttribute", "AttributeRef", "Attribute"
          )
        end
        { type: reference ? :reference_selector : :drop_down,
          name: widget["Name"], options: options.compact, events: grid_events(widget) }
      end

      def custom_property_map(object, object_type)
        return {} unless object.is_a?(Hash) && object_type.is_a?(Hash)

        types = parse_array(object_type["PropertyTypes"]).to_h do |type|
          [IO::BsonCodec.extract_id(type["$ID"]), type["PropertyKey"]]
        end
        parse_array(object["Properties"]).to_h do |property|
          [types[IO::BsonCodec.extract_id(property["TypePointer"])], property["Value"]]
        end.compact
      end

      def custom_property_type(object_type, key)
        parse_array(object_type && object_type["PropertyTypes"]).find { _1["PropertyKey"] == key }
      end

      def parse_search_bar(sb)
        return nil unless sb.is_a?(Hash)
        fields = parse_array(sb["SearchFields"]).filter_map do |sf|
          attr_ref = sf.dig("AttributeRef", "Attribute") || sf["Attribute"] || sf["AttributePath"]
          next unless attr_ref
          {
            attribute: attr_ref.to_s.split("/").last,
            caption: extract_text(sf["Label"] || sf["Caption"])
          }
        end
        fields.empty? ? nil : { fields: fields }
      end

      def parse_toolbar(tb)
        return nil unless tb.is_a?(Hash)
        type_map = {
          "Pages$GridNewButton"              => :new,
          "Forms$GridNewButton"              => :new,
          "Pages$GridDeleteButton"           => :delete,
          "Forms$GridDeleteButton"           => :delete,
          "Pages$GridSearchButton"           => :search,
          "Forms$GridSearchButton"           => :search,
          "Pages$GridExportToExcelButton"    => :export,
          "Forms$GridExportToExcelButton"    => :export
        }
        buttons = parse_array(tb["Buttons"]).filter_map do |btn|
          t = type_map[btn["$Type"]]
          next unless t
          { type: t, caption: extract_text(btn["Caption"]) }
        end
        buttons.empty? ? nil : { buttons: buttons }
      end

      def tab_control_widget(widget)
        tabs = parse_array(widget["TabPages"]).map do |tab|
          widgets = []
          parse_widgets(parse_array(tab["Widgets"]), widgets)
          {
            name: tab["Name"],
            caption: extract_text(tab["Caption"]),
            widgets: widgets
          }.compact
        end
        {
          type: :tab_control,
          name: widget["Name"],
          options: { tabs: tabs },
          events: []
        }
      end

      def grid_entity(widget)
        widget.dig("DataSource", "Entity") ||
          widget.dig("DataSource", "EntityRef", "Entity")
      end

      def widget_roots(doc)
        roots = parse_array(doc["Widgets"] || doc["widgets"])
        roots.concat(form_call_widgets(doc["FormCall"]))
        roots
      end

      def form_call_widgets(form_call)
        return [] unless form_call.is_a?(Hash)

        parse_array(form_call["Arguments"]).flat_map do |argument|
          child_widgets(argument)
        end
      end

      def parse_form_call_arguments(arguments, target = @widgets)
        parse_array(arguments).each do |argument|
          parse_widgets(child_widgets(argument), target)
        end
      end

      def layout_container?(widget)
        child_widgets(widget).any? || widget.key?("Arguments")
      end

      def child_widgets(widget)
        direct = parse_array(widget["Widgets"]) + parse_array(widget["FooterWidgets"])
        tab_widgets = parse_array(widget["TabPages"]).flat_map { parse_array(_1["Widgets"]) }
        row_columns = parse_array(widget["Rows"]).flat_map { parse_array(_1["Columns"]) }
        column_widgets = row_columns.flat_map { parse_array(_1["Widgets"]) }
        direct + tab_widgets + column_widgets
      end

      def parse_source(source)
        return nil unless source.is_a?(Hash)
        result = if %w[Pages$NanoflowSource Forms$NanoflowSource].include?(source["$Type"])
          { kind: :nanoflow, name: source_name(source["Nanoflow"] || source.dig("NanoflowSettings", "Nanoflow")) }
        else
          { kind: :microflow, name: source_name(source["Microflow"] || source.dig("MicroflowSettings", "Microflow")) }
        end
        result[:name].to_s.empty? ? nil : result
      end

      # Page data sources are architectural references. Unlike widget-local
      # action handlers, their module qualification must survive export so a
      # native Core.Flow reference cannot silently become Portal.Flow.
      def source_name(name)
        name.to_s
      end

      def parse_action(action)
        return nil unless action.is_a?(Hash)
        if %w[Pages$CallNanoflowClientAction Forms$CallNanoflowClientAction].include?(action["$Type"])
          settings = action["NanoflowSettings"] || action
          handler = local_name(action["Nanoflow"] || settings["Nanoflow"])
          return nil if handler.to_s.empty?

          arguments = parse_array(settings["ParameterMappings"]).to_h do |mapping|
            [local_name(mapping["Parameter"]), mapping["Expression"].to_s]
          end
          { kind: :nanoflow, handler: handler, arguments: arguments }
        elsif %w[Pages$MicroflowClientAction Forms$MicroflowAction Forms$MicroflowClientAction].include?(action["$Type"])
          settings = action["MicroflowSettings"] || action
          handler = local_name(action["Microflow"] || settings["Microflow"])
          return nil if handler.to_s.empty?

          arguments = parse_array(settings["ParameterMappings"]).to_h do |mapping|
            [local_name(mapping["Parameter"]), mapping["Expression"].to_s]
          end
          { kind: :microflow, handler: handler, arguments: arguments }
        elsif %w[Pages$FormAction Forms$FormAction].include?(action["$Type"])
          settings = action["FormSettings"] || action
          handler = settings["Form"].to_s
          return nil if handler.empty?

          arguments = parse_array(settings["ParameterMappings"]).to_h do |mapping|
            [local_name(mapping["Parameter"]), mapping["Expression"].to_s]
          end
          { kind: :page, handler: handler, arguments: arguments }
        elsif %w[Pages$SaveChangesClientAction Forms$SaveChangesClientAction].include?(action["$Type"])
          { kind: :action, handler: "save_changes" }
        elsif %w[Pages$CancelChangesClientAction Forms$CancelChangesClientAction].include?(action["$Type"])
          { kind: :action, handler: "cancel_changes" }
        elsif %w[Pages$DeleteClientAction Forms$DeleteClientAction].include?(action["$Type"])
          { kind: :action, handler: "delete" }
        elsif %w[Pages$ClosePageClientAction Forms$ClosePageClientAction].include?(action["$Type"])
          { kind: :action, handler: "close_page" }
        end
      end

      def local_name(name)
        name.to_s.split(".").last
      end
    end
  end
end
