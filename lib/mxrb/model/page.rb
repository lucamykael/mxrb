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
                  :widgets, :data_source, :raw_document

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
          if %w[Pages$DataGrid Forms$DataGrid].include?(type)
            target << data_grid_widget(widget)
            next
          end
          if %w[Pages$TabControl Forms$TabControl].include?(type)
            target << tab_control_widget(widget)
            next
          end
          if %w[Pages$SnippetCall Forms$SnippetCall].include?(type)
            snippet_ref = widget.dig("SnippetSettings", "Snippet").to_s
            target << { type: :snippet, name: widget["Name"] || "snippet",
                        options: { snippet: snippet_ref }, events: [] }
            next
          end
          if %w[Pages$Container Forms$Container].include?(type)
            children = []
            parse_widgets(parse_array(widget["Widgets"]), children)
            target << { type: :container, name: widget["Name"] || "container",
                        options: {}, children: children, events: [] }
            next
          end
          if layout_container?(widget)
            parse_widgets(child_widgets(widget), target)
            parse_form_call_arguments(widget["Arguments"], target)
            next
          end
          next unless supported_widget?(type)

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
        when "Pages$CheckBox", "Forms$CheckBox"
          :check_box
        when "Pages$DatePicker", "Forms$DatePicker"
          :date_picker
        when "Pages$ReferenceSelector", "Forms$ReferenceSelector",
             "Pages$InputReferenceSetSelector", "Forms$InputReferenceSetSelector"
          :reference_selector
        when "Pages$DynamicText", "Forms$DynamicText", "Pages$Label", "Forms$Label"
          :text
        when "Pages$DropDownWidget", "Forms$DropDownWidget"
          :drop_down
        end
      end

      def widget_options(widget, widget_type)
        {
          attribute: attribute_path(widget),
          caption: widget_caption(widget, widget_type)
        }.compact
      end

      def attribute_path(widget)
        widget["AttributePath"] || widget.dig("AttributeRef", "Attribute")
      end

      def widget_caption(widget, widget_type)
        return extract_text(widget["Content"] || widget["Text"] || widget["LabelText"]) if widget_type == :text

        extract_text(
          widget["Caption"] ||
          widget["LabelText"] ||
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
        { type: :data_grid, name: widget["Name"], options: options, events: [] }
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
          {
            name: tab["Name"],
            caption: extract_text(tab["Caption"])
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
          { kind: :nanoflow, name: local_name(source["Nanoflow"] || source.dig("NanoflowSettings", "Nanoflow")) }
        else
          { kind: :microflow, name: local_name(source["Microflow"] || source.dig("MicroflowSettings", "Microflow")) }
        end
        result[:name].to_s.empty? ? nil : result
      end

      def parse_action(action)
        return nil unless action.is_a?(Hash)
        if %w[Pages$CallNanoflowClientAction Forms$CallNanoflowClientAction].include?(action["$Type"])
          handler = local_name(action["Nanoflow"] || action.dig("NanoflowSettings", "Nanoflow"))
          handler.to_s.empty? ? nil : { kind: :nanoflow, handler: handler }
        elsif %w[Pages$MicroflowClientAction Forms$MicroflowAction Forms$MicroflowClientAction].include?(action["$Type"])
          handler = local_name(action["Microflow"] || action.dig("MicroflowSettings", "Microflow"))
          handler.to_s.empty? ? nil : { kind: :microflow, handler: handler }
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
