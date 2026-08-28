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
                    :system_members, :lifecycle, :source, :oql_query, :native_type

      # Build from a BSON hash (embedded in DomainModel's "entities" array).
      def self.from_bson(doc, _domain_model_id, mpr)
        e                    = new
        e.id                 = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        e.name               = doc["name"]  || doc["Name"]
        e.qualified_name     = doc["$QualifiedName"] || doc["\$QualifiedName"]
        e.documentation      = doc["documentation"] || doc["Documentation"] || ""
        e.native_type        = doc["$Type"]
        e.source             = doc["source"] || doc["Source"]
        e.oql_query          = doc["oqlQuery"] || doc["OqlQuery"] || doc["OQLQuery"]
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
        raw_indexes = IO::BsonCodec.parse_array(doc['indexes'] || doc['Indexes'])[:items]
        e.indexes = normalize_indexes(raw_indexes, e.attributes, e.qualified_name)

        # Access rules (embedded array with marker 3)
        rule_arr = IO::BsonCodec.parse_array(doc["accessRules"] || doc["AccessRules"])[:items]
        e.access_rules = rule_arr.map { parse_access_rule(_1) }
        event_arr = IO::BsonCodec.parse_array(doc["eventHandlers"] || doc["EventHandlers"])[:items]
        e.lifecycle = event_arr.map { parse_lifecycle(_1) }

        e
      end

      def attributes = @attributes || []

      def generalization_target
        return unless @generalization.is_a?(Hash)

        @generalization['generalization'] || @generalization['Generalization']
      end

      def oql_view?
        source_type = @source.is_a?(Hash) ? @source.fetch('$Type', '') : ''
        @native_type.to_s.match?(/ViewEntity/i) ||
          source_type.match?(/OqlViewEntitySource/i) ||
          !@oql_query.to_s.empty?
      end

      def oql_source_document
        return unless @source.is_a?(Hash)

        @source['SourceDocument'] || @source['sourceDocument']
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
          "eventHandlers"   => IO::BsonCodec.build_array(@lifecycle.to_a.map { lifecycle_bson(_1) }),
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

      def self.normalize_indexes(indexes, attributes, qualified_name)
        names_by_id = attributes.to_h { [_1.id, _1.name] }
        indexes.each do |index|
          members = IO::BsonCodec.parse_array(index['Attributes'])[:items]
          members.each do |member|
            next if member['Attribute'] || member['attribute']

            id = IO::BsonCodec.extract_id(member['AttributePointer'])
            name = names_by_id[id]
            member['Attribute'] = [qualified_name, name].compact.join('.') if name
          end
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
          { id: IO::BsonCodec.extract_id(m["$ID"]),
            name: attr_ref.to_s.split(%r{[/.]}).last, reference: attr_ref.to_s,
            rights: m["AccessRights"] || "None", kind: kind }
        end
        {
          id: IO::BsonCodec.extract_id(doc["$ID"]),
          roles: roles,
          create: doc["AllowCreate"] == true,
          delete: doc["AllowDelete"] == true,
          documentation: doc["Documentation"].to_s,
          default_rights: default_rights,
          members: members,
          xpath: doc["XPathConstraint"] || "",
          xpath_caption: doc["XPathConstraintCaption"]
        }
      end

      def self.parse_lifecycle(doc)
        moment = doc["Moment"].to_s.downcase
        event = doc["Event"].to_s.downcase
        {
          event: [moment, event].reject(&:empty?).join("_").to_sym,
          handler: doc["Microflow"].to_s,
          pass_event_object: doc.fetch("PassEventObject", true) == true,
          raise_error_on_false: doc["RaiseErrorOnFalse"] == true
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

      def lifecycle_bson(callback)
        moment, event = callback.fetch(:event).to_s.split("_", 2)
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "DomainModels$EventHandler",
          "Event" => event.to_s.capitalize,
          "Moment" => moment.to_s.capitalize,
          "Microflow" => callback.fetch(:handler).to_s,
          "PassEventObject" => callback.fetch(:pass_event_object, true) == true,
          "RaiseErrorOnFalse" => callback.fetch(:raise_error_on_false, false) == true
        }
      end
    end
  end
end
