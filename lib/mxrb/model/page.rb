# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Pages$Page
    # ContainmentName: "Documents"
    class Page < Unit
      attr_reader :name, :documentation, :url, :layout_id, :title,
                  :popup_width, :popup_height, :popup_resizable, :excluded,
                  :allowed_module_roles, :parameters, :export_level

      def decode(doc)
        @name                = doc["Name"] || doc["name"]
        @documentation       = doc["Documentation"] || doc["documentation"] || ""
        @url                 = doc["Url"] || doc["URL"] || doc["url"] || ""
        @title               = extract_text(doc["Title"] || doc["title"])
        @layout_id           = IO::BsonCodec.extract_id(doc["Layout"] || doc["LayoutId"])
        @popup_width         = doc["PopupWidth"] || 0
        @popup_height        = doc["PopupHeight"] || 0
        @popup_resizable     = doc["PopupResizable"] == true
        @excluded            = doc["Excluded"] == true
        @export_level        = doc["ExportLevel"] || "Hidden"
        @allowed_module_roles = parse_array(doc["AllowedModuleRoles"] || doc["allowedModuleRoles"])
        @parameters          = parse_array(doc["Parameters"] || doc["parameters"])
      end

      def to_bson
        {
          "$ID"                => @id,
          "$Type"              => "Pages$Page",
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
        "#<Mxrb::Page name=#{@name.inspect} layout=#{@layout_id&.slice(0, 8)}>"
      end

      private

      def extract_text(obj)
        return obj if obj.is_a?(String)
        return "" unless obj.is_a?(Hash)
        translations = obj["Translations"] || obj["translations"] || []
        translations.first&.dig("Translation") || ""
      end

      def serialize_title
        { "$ID" => SecureRandom.uuid, "$Type" => "Texts$Text", "Translations" => [1] }
      end
    end
  end
end
