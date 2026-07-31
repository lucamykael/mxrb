# frozen_string_literal: true

require_relative "attribute"

module Mxrb
  module Model
    # Entities are embedded in the DomainModel BSON — NOT separate Unit rows.
    # $Type: DomainModels$Entity (read) / DomainModels$EntityImpl (write)
    class Entity # rubocop:disable Metrics/ClassLength
      attr_accessor :id, :name, :qualified_name, :documentation,
                    :persistable, :location, :data_storage_guid,
                    :export_level, :generalization, :access_rules, :indexes,
                    :system_members

      # Build from a BSON hash (embedded in DomainModel's "entities" array).
      def self.from_bson(doc, _domain_model_id, mpr)
        e                    = new
        e.id                 = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        e.name               = doc["name"]  || doc["Name"]
        e.qualified_name     = doc["$QualifiedName"] || doc["\$QualifiedName"]
        e.documentation      = doc["documentation"] || doc["Documentation"] || ""
        e.data_storage_guid  = doc["dataStorageGuid"] || doc["DataStorageGuid"]
        e.export_level       = doc["exportLevel"] || doc["ExportLevel"] || "Hidden"
        e.location           = parse_location(doc["location"] || doc["Location"])

        # Persistable lives inside generalization.NoGeneralization.persistable
        gen = doc["generalization"] || doc["Generalization"] ||
              doc["maybeGeneralization"] || doc["MaybeGeneralization"]
        e.generalization = gen
        persistable = if gen.is_a?(Hash)
                        gen.fetch('persistable', gen.fetch('Persistable', true))
                      else
                        true
                      end
        e.persistable = persistable != false
        e.system_members = parse_system_members(gen)

        # Attributes (embedded array with marker)
        attr_arr   = IO::BsonCodec.parse_array(doc["attributes"] || doc["Attributes"])[:items]
        e.instance_variable_set(:@attributes, attr_arr.map { Attribute.from_bson(_1) })
        rules = IO::BsonCodec.parse_array(doc['validationRules'] || doc['ValidationRules'])[:items]
        apply_validation_rules(e.attributes, rules)
        e.indexes = IO::BsonCodec.parse_array(doc['indexes'] || doc['Indexes'])[:items]

        # Access rules (embedded array with marker 3)
        rule_arr = IO::BsonCodec.parse_array(doc["accessRules"] || doc["AccessRules"])[:items]
        e.access_rules = rule_arr.map { parse_access_rule(_1) }

        e
      end

      def attributes = @attributes || []

      def generalization_target
        return unless @generalization.is_a?(Hash)

        @generalization['generalization'] || @generalization['Generalization']
      end

      def to_bson
        {
          "$ID"             => @id,
          "$Type"           => "DomainModels$EntityImpl",
          "$QualifiedName"  => @qualified_name,
          "name"            => @name,
          "documentation"   => @documentation || "",
          "dataStorageGuid" => @data_storage_guid || SecureRandom.uuid,
          "location"        => serialize_location(@location),
          "generalization"  => serialize_generalization,
          "attributes"      => IO::BsonCodec.build_array(@attributes.map(&:to_bson)),
          "validationRules" => IO::BsonCodec.build_array([]),  # must come after attributes
          "eventHandlers"   => IO::BsonCodec.build_array([]),
          "indexes"         => IO::BsonCodec.build_array([]),
          "accessRules"     => IO::BsonCodec.build_array(@access_rules.to_a),
          "source"          => nil,
          "exportLevel"     => @export_level || "Hidden",
          "image"           => "",
          "imageData"       => "",
        }
      end

      def inspect
        "#<Mxrb::Entity name=#{@name.inspect} attrs=#{attributes.size} persistable=#{@persistable}>"
      end

      private

      def self.apply_validation_rules(attributes, rules)
        by_name = attributes.to_h { [_1.name, _1] }
        rules.each do |rule|
          attribute = by_name[rule['Attribute'].to_s.split('.').last]
          next unless attribute

          kind = rule.dig('RuleInfo', '$Type').to_s
          attribute.required = true if kind.end_with?('RequiredRuleInfo')
          attribute.unique = true if kind.end_with?('UniqueRuleInfo')
        end
      end

      def self.parse_system_members(generalization)
        return {} unless generalization.is_a?(Hash)

        {
          owner: generalization['hasOwner'] == true || generalization['HasOwnerAttr'] == true,
          created_date: generalization.values_at(
            'hasCreatedDate', 'HasCreatedDateAttr'
          ).include?(true),
          changed_date: generalization.values_at(
            'hasChangedDate', 'HasChangedDateAttr'
          ).include?(true),
          changed_by: generalization.values_at(
            'hasChangedBy', 'HasChangedByAttr'
          ).include?(true)
        }
      end

      def self.parse_access_rule(doc)
        roles = IO::BsonCodec.parse_array(doc["ModuleRoles"] || doc["AllowedModuleRoles"])[:items]
        default_rights = doc["DefaultMemberAccessRights"] || "None"
        member_items = IO::BsonCodec.parse_array(doc["MemberAccesses"])[:items]
        members = member_items.map do |m|
          association_ref = m["Association"].to_s
          attr_ref = association_ref.empty? ? m["Attribute"] : association_ref
          kind = association_ref.empty? ? :attribute : :association
          { name: attr_ref.to_s.split(%r{[/.]}).last,
            rights: m["AccessRights"] || "None", kind: kind }
        end
        {
          roles: roles,
          create: doc["AllowCreate"] == true,
          delete: doc["AllowDelete"] == true,
          default_rights: default_rights,
          members: members,
          xpath: doc["XPathConstraint"] || ""
        }
      end

      def self.parse_location(loc)
        if loc.is_a?(String)
          x, y = loc.split(';', 2).map(&:to_i)
          return { x: x, y: y }
        end
        return { x: 0, y: 0 } unless loc.is_a?(Hash)
        { x: loc["x"] || loc[:x] || 0, y: loc["y"] || loc[:y] || 0 }
      end

      def serialize_location(loc)
        return { "x" => 0, "y" => 0 } unless loc
        { "x" => loc[:x] || 0, "y" => loc[:y] || 0 }
      end

      def serialize_generalization
        @generalization || {
          "$ID"             => SecureRandom.uuid,
          "$Type"           => "DomainModels$NoGeneralization",
          "persistable"     => @persistable != false,
          "hasChangedDate"  => false,
          "hasCreatedDate"  => false,
          "hasOwner"        => false,
          "hasChangedBy"    => false,
        }
      end
    end
  end
end
