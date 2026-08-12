# frozen_string_literal: true

require "securerandom"

module Mxrb
  module Semantic
    # Shared BSON helpers for entity validation rules.
    module DomainValidationRules
      module_function

      def extract(entity_doc)
        IO::BsonCodec.parse_array(
          entity_doc["validationRules"] || entity_doc["ValidationRules"]
        )[:items]
      end

      def put(entity_doc, rules)
        key = entity_doc.key?("validationRules") ? "validationRules" : "ValidationRules"
        entity_doc[key] = IO::BsonCodec.build_array(rules)
      end

      def for_attribute?(rule, attribute_name, kind = nil)
        matches_attribute = rule["Attribute"].to_s.split(".").last == attribute_name.to_s
        return matches_attribute unless kind

        rule_kind = rule.dig("RuleInfo", "$Type").to_s
        matches_attribute && rule_kind.end_with?("#{kind.to_s.capitalize}RuleInfo")
      end

      def build(module_name, entity_name, attribute_name, kind)
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "DomainModels$ValidationRule",
          "Attribute" => "#{module_name}.#{entity_name}.#{attribute_name}",
          "Message" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Texts$Text",
            "Items" => IO::BsonCodec.build_array([{
              "$ID" => SecureRandom.uuid,
              "$Type" => "Texts$Translation",
              "LanguageCode" => "en_US",
              "Text" => "#{attribute_name} #{kind == :required ? 'is required' : 'must be unique'}"
            }])
          },
          "RuleInfo" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "DomainModels$#{kind.to_s.capitalize}RuleInfo"
          }
        }
      end
    end

    # Plan that adds a new attribute to an existing entity.
    class AddAttributePlan
      attr_reader :changes

      def initialize(project:, module_name:, entity_name:, entity_id:, domain_unit_id:, attribute_def:)
        @project        = project
        @module_name    = module_name
        @entity_name    = entity_name
        @entity_id      = entity_id
        @domain_unit_id = domain_unit_id
        @attribute_def  = attribute_def
        @applied        = false
        @changes = ["add #{attribute_def[:name]} (#{attribute_def[:type]}) to " \
                    "#{module_name}.#{entity_name}"].freeze
      end

      def empty?   = false
      def applied? = @applied

      def apply!
        raise ArgumentError, "plan was already applied" if @applied

        @project.mpr.transaction do
          raw = @project.raw_unit(@domain_unit_id)
          raise ArgumentError, "domain model unit not found" unless raw

          doc      = @project.parse_bson(raw)
          entities = DomainMutator.extract_entities(doc)
          entity_doc = entities.find { IO::BsonCodec.extract_id(_1["$ID"] || _1["\$ID"]) == @entity_id }
          raise ArgumentError, "entity #{@entity_name.inspect} not found in domain model" unless entity_doc

          attrs = DomainMutator.extract_attributes(entity_doc)
          existing = attrs.map { (_1["name"] || _1["Name"]).to_s }
          raise ArgumentError, "attribute #{@attribute_def[:name]} already exists on #{@entity_name}" \
            if existing.include?(@attribute_def[:name].to_s)

          new_attr = Writer.new("", {}).build_domain_attribute_document(@attribute_def)
          DomainMutator.put_attributes(entity_doc, attrs + [new_attr])
          %i[required unique].each do |kind|
            next unless @attribute_def[kind] == true

            rules = DomainValidationRules.extract(entity_doc)
            rules << DomainValidationRules.build(
              @module_name, @entity_name, @attribute_def[:name], kind
            )
            DomainValidationRules.put(entity_doc, rules)
          end
          DomainMutator.put_entity(doc, @entity_id, entity_doc)
          @project.mpr.update_unit(@domain_unit_id, doc)
        end

        @project.refresh!
        @applied = true
        self
      end
    end

    # Plan that removes an attribute from an entity, with incoming reference check.
    class RemoveAttributePlan
      attr_reader :attribute_name, :incoming, :changes

      def initialize(project:, module_name:, entity_name:, entity_id:, domain_unit_id:,
                     attribute_name:, incoming:)
        @project        = project
        @module_name    = module_name
        @entity_name    = entity_name
        @entity_id      = entity_id
        @domain_unit_id = domain_unit_id
        @attribute_name = attribute_name
        @incoming       = incoming.freeze
        @applied        = false
        @changes = ["remove #{module_name}.#{entity_name}/#{attribute_name}"].freeze
      end

      def safe?    = @incoming.empty?
      def empty?   = false
      def applied? = @applied

      def apply!
        raise ArgumentError, "plan was already applied" if @applied
        unless safe?
          raise ArgumentError,
                "cannot remove #{@module_name}.#{@entity_name}/#{@attribute_name}: " \
                "#{@incoming.size} incoming reference(s)"
        end

        @project.mpr.transaction do
          raw = @project.raw_unit(@domain_unit_id)
          raise ArgumentError, "domain model unit not found" unless raw

          doc        = @project.parse_bson(raw)
          entities   = DomainMutator.extract_entities(doc)
          entity_doc = entities.find { IO::BsonCodec.extract_id(_1["$ID"] || _1["\$ID"]) == @entity_id }
          raise ArgumentError, "entity not found" unless entity_doc

          attrs = DomainMutator.extract_attributes(entity_doc)
          before_size = attrs.size
          attrs.reject! { (_1["name"] || _1["Name"]).to_s == @attribute_name }
          raise ArgumentError, "attribute #{@attribute_name.inspect} not found on #{@entity_name}" \
            if attrs.size == before_size

          DomainMutator.put_attributes(entity_doc, attrs)
          rules = DomainValidationRules.extract(entity_doc).reject do |rule|
            DomainValidationRules.for_attribute?(rule, @attribute_name)
          end
          DomainValidationRules.put(entity_doc, rules)
          DomainMutator.put_entity(doc, @entity_id, entity_doc)
          @project.mpr.update_unit(@domain_unit_id, doc)
        end

        @project.refresh!
        @applied = true
        self
      end
    end

    # Plan that changes an attribute's type, default value, or documentation.
    class ChangeAttributePlan
      attr_reader :attribute_name, :updates, :changes

      def initialize(project:, module_name:, entity_name:, entity_id:, domain_unit_id:,
                     attribute_name:, updates:)
        @project        = project
        @module_name    = module_name
        @entity_name    = entity_name
        @entity_id      = entity_id
        @domain_unit_id = domain_unit_id
        @attribute_name = attribute_name
        @updates        = updates.freeze
        @applied        = false
        desc = updates.map { |k, v| "#{k}: #{v}" }.join(", ")
        @changes = ["change #{module_name}.#{entity_name}/#{attribute_name} (#{desc})"].freeze
      end

      def empty?   = false
      def applied? = @applied

      def apply!
        raise ArgumentError, "plan was already applied" if @applied

        @project.mpr.transaction do
          raw = @project.raw_unit(@domain_unit_id)
          raise ArgumentError, "domain model unit not found" unless raw

          doc        = @project.parse_bson(raw)
          entities   = DomainMutator.extract_entities(doc)
          entity_doc = entities.find { IO::BsonCodec.extract_id(_1["$ID"] || _1["\$ID"]) == @entity_id }
          raise ArgumentError, "entity not found" unless entity_doc

          attrs    = DomainMutator.extract_attributes(entity_doc)
          attr_doc = attrs.find { (_1["name"] || _1["Name"]).to_s == @attribute_name }
          raise ArgumentError, "attribute #{@attribute_name.inspect} not found on #{@entity_name}" unless attr_doc

          attr_model = Model::Attribute.from_bson(attr_doc)
          attribute_def = {
            name: @attribute_name,
            type: @updates.fetch(:type, attr_model.type),
            default: @updates.fetch(:default, attr_model.default_value),
            documentation: @updates.fetch(:documentation, attr_model.documentation),
            length: @updates.fetch(:length, attr_model.length),
            localize_date: @updates.fetch(:localize_date, attr_model.localize_date),
            enumeration: @updates.fetch(:enumeration, attr_model.enumeration)
          }
          replacement = Writer.new("", {}).build_domain_attribute_document(
            attribute_def, previous: attr_doc
          )
          new_attrs = attrs.map { (_1["name"] || _1["Name"]).to_s == @attribute_name ? replacement : _1 }
          DomainMutator.put_attributes(entity_doc, new_attrs)
          %i[required unique].each do |kind|
            next unless @updates.key?(kind)

            rules = DomainValidationRules.extract(entity_doc).reject do |rule|
              DomainValidationRules.for_attribute?(rule, @attribute_name, kind)
            end
            rules << DomainValidationRules.build(@module_name, @entity_name, @attribute_name, kind) \
              if @updates[kind] == true
            DomainValidationRules.put(entity_doc, rules)
          end
          DomainMutator.put_entity(doc, @entity_id, entity_doc)
          @project.mpr.update_unit(@domain_unit_id, doc)
        end

        @project.refresh!
        @applied = true
        self
      end
    end

    # Plan that adds a new entity to a module's domain model.
    class AddEntityPlan
      attr_reader :entity_def, :module_name, :changes

      def initialize(project:, module_name:, domain_unit_id:, entity_def:)
        @project        = project
        @module_name    = module_name
        @domain_unit_id = domain_unit_id
        @entity_def     = entity_def
        @applied        = false
        @changes = ["add entity #{module_name}.#{entity_def[:name]}"].freeze
      end

      def empty?   = false
      def applied? = @applied

      def apply!
        raise ArgumentError, "plan was already applied" if @applied

        @project.mpr.transaction do
          raw = @project.raw_unit(@domain_unit_id)
          raise ArgumentError, "domain model unit not found" unless raw

          doc      = @project.parse_bson(raw)
          entities = DomainMutator.extract_entities(doc)
          existing_names = entities.map { (_1["name"] || _1["Name"]).to_s }
          raise ArgumentError, "entity #{@entity_def[:name]} already exists in #{@module_name}" \
            if existing_names.include?(@entity_def[:name].to_s)

          entities_key = DomainMutator.entities_key(doc)
          definition = {
            name: @entity_def[:name].to_s,
            documentation: @entity_def.fetch(:documentation, "").to_s,
            persistable: !@entity_def[:non_persistent],
            attributes: Array(@entity_def[:attributes]),
            access_rules: nil,
            indexes: nil,
            lifecycle: nil
          }
          entity_doc = Writer.new("", {}).build_domain_entity_document(
            definition, module_name: @module_name, index: entities.size
          )
          doc[entities_key] = IO::BsonCodec.build_array(entities + [entity_doc])
          @project.mpr.update_unit(@domain_unit_id, doc)
        end

        @project.refresh!
        @applied = true
        self
      end
    end

    # Plan that removes an entity (and all its embedded attributes) from the domain model.
    class RemoveEntityPlan
      attr_reader :entity_name, :incoming, :changes

      def initialize(project:, module_name:, entity_name:, entity_id:, domain_unit_id:, incoming:)
        @project        = project
        @module_name    = module_name
        @entity_name    = entity_name
        @entity_id      = entity_id
        @domain_unit_id = domain_unit_id
        @incoming       = incoming.freeze
        @applied        = false
        @changes = ["remove entity #{module_name}.#{entity_name}"].freeze
      end

      def safe?    = @incoming.empty?
      def empty?   = false
      def applied? = @applied

      def apply!
        raise ArgumentError, "plan was already applied" if @applied
        unless safe?
          raise ArgumentError,
                "cannot remove #{@module_name}.#{@entity_name}: " \
                "#{@incoming.size} incoming reference(s)"
        end

        @project.mpr.transaction do
          raw = @project.raw_unit(@domain_unit_id)
          raise ArgumentError, "domain model unit not found" unless raw

          doc      = @project.parse_bson(raw)
          entities = DomainMutator.extract_entities(doc)
          before_size = entities.size
          entities.reject! { IO::BsonCodec.extract_id(_1["$ID"] || _1["\$ID"]) == @entity_id }
          raise ArgumentError, "entity #{@entity_name.inspect} not found" if entities.size == before_size

          entities_key = DomainMutator.entities_key(doc)
          doc[entities_key] = IO::BsonCodec.build_array(entities)
          @project.mpr.update_unit(@domain_unit_id, doc)
        end

        @project.refresh!
        @applied = true
        self
      end
    end

    # Factory for domain model mutation plans exposed through Project.
    class DomainMutator # rubocop:disable Metrics/ClassLength
      UNSET = Object.new.freeze

      def initialize(project)
        @project = project
      end

      def plan_add_attribute(entity_qname, name:, type: :string, default: nil, documentation: nil,
                             required: false, unique: false, length: nil, localize_date: nil,
                             enumeration: nil)
        mod_name, entity_name, dm_id, entity_id = resolve_entity(entity_qname)
        AddAttributePlan.new(
          project: @project, module_name: mod_name, entity_name: entity_name,
          entity_id: entity_id, domain_unit_id: dm_id,
          attribute_def: {
            name: name.to_s, type: type, default: default,
            documentation: documentation.to_s, required: required == true,
            unique: unique == true, length:, localize_date:, enumeration:
          }
        )
      end

      def plan_remove_attribute(attribute_qname)
        mod_name, entity_name, dm_id, entity_id, attr_name = resolve_attribute(attribute_qname)
        # Attribute qualified names in the semantic index use dots: M.Entity.Attr
        artifact = @project.find_artifact("#{mod_name}.#{entity_name}.#{attr_name}", kind: :attribute)
        incoming = artifact ? @project.references_to(artifact) : []
        RemoveAttributePlan.new(
          project: @project, module_name: mod_name, entity_name: entity_name,
          entity_id: entity_id, domain_unit_id: dm_id,
          attribute_name: attr_name, incoming: incoming
        )
      end

      def plan_change_attribute(attribute_qname, type: UNSET, default: UNSET,
                                documentation: UNSET, required: UNSET, unique: UNSET,
                                length: UNSET, localize_date: UNSET, enumeration: UNSET)
        mod_name, entity_name, dm_id, entity_id, attr_name = resolve_attribute(attribute_qname)
        updates = {}
        {
          type:, default:, documentation:, required:, unique:, length:,
          localize_date:, enumeration:
        }.each { |key, value| updates[key] = value unless value.equal?(UNSET) }
        raise ArgumentError, "plan_change_attribute: no changes specified" if updates.empty?

        ChangeAttributePlan.new(
          project: @project, module_name: mod_name, entity_name: entity_name,
          entity_id: entity_id, domain_unit_id: dm_id,
          attribute_name: attr_name, updates: updates
        )
      end

      def plan_add_entity(module_qname, name:, attributes: [], documentation: nil, non_persistent: false)
        mod_name, dm_id = resolve_module(module_qname)
        AddEntityPlan.new(
          project: @project, module_name: mod_name, domain_unit_id: dm_id,
          entity_def: {
            name: name.to_s, attributes: attributes,
            documentation: documentation.to_s, non_persistent: non_persistent
          }
        )
      end

      def plan_remove_entity(entity_qname)
        mod_name, entity_name, dm_id, entity_id = resolve_entity(entity_qname)
        artifact = @project.find_artifact(entity_qname, kind: :entity)
        incoming = artifact ? @project.references_to(artifact).reject { _1.source.qualified_name == entity_qname } : []
        RemoveEntityPlan.new(
          project: @project, module_name: mod_name, entity_name: entity_name,
          entity_id: entity_id, domain_unit_id: dm_id, incoming: incoming
        )
      end

      # ── BSON helpers used by plans ──────────────────────────────────────────

      def self.extract_entities(doc)
        IO::BsonCodec.parse_array(doc["entities"] || doc["Entities"])[:items]
      end

      def self.entities_key(doc)
        doc.key?("entities") ? "entities" : "Entities"
      end

      def self.extract_attributes(entity_doc)
        IO::BsonCodec.parse_array(entity_doc["attributes"] || entity_doc["Attributes"])[:items]
      end

      def self.put_attributes(entity_doc, attrs)
        key = entity_doc.key?("attributes") ? "attributes" : "Attributes"
        entity_doc[key] = IO::BsonCodec.build_array(attrs)
      end

      def self.put_entity(domain_doc, entity_id, updated_entity_doc)
        key      = entities_key(domain_doc)
        entities = IO::BsonCodec.parse_array(domain_doc[key])[:items]
        updated  = entities.map do |e|
          IO::BsonCodec.extract_id(e["$ID"] || e["\$ID"]) == entity_id ? updated_entity_doc : e
        end
        domain_doc[key] = IO::BsonCodec.build_array(updated)
      end

      private

      def resolve_module(name)
        mod = @project.modules.find { _1.name == name.to_s }
        raise KeyError, "module #{name.inspect} not found" unless mod

        dm = mod.domain_model
        raise ArgumentError, "module #{name} has no domain model" unless dm

        [mod.name, dm.id]
      end

      def resolve_entity(qname)
        parts = qname.to_s.split(".", 2)
        raise ArgumentError, "expected ModuleName.EntityName, got #{qname.inspect}" unless parts.size == 2

        mod_name, entity_name = parts
        mod = @project.modules.find { _1.name == mod_name }
        raise KeyError, "module #{mod_name.inspect} not found" unless mod

        dm = mod.domain_model
        raise ArgumentError, "module #{mod_name} has no domain model" unless dm

        entity = mod.entities.find { _1.name == entity_name }
        raise KeyError, "entity #{qname.inspect} not found" unless entity

        [mod_name, entity_name, dm.id, entity.id]
      end

      def resolve_attribute(qname)
        entity_part, attr_name = qname.to_s.split("/", 2)
        raise ArgumentError, "expected M.Entity/AttributeName, got #{qname.inspect}" unless attr_name

        [*resolve_entity(entity_part), attr_name]
      end
    end
  end
end
