# frozen_string_literal: true

require "digest"

module Mxrb
  module Compare
    Change = Data.define(:operation, :path, :before, :after) do
      def added? = operation == :added
      def removed? = operation == :removed
      def changed? = operation == :changed
    end

    Result = Struct.new(:differences, :changes, keyword_init: true) do
      def identical? = differences.empty?
      def added = changes.select(&:added?)
      def removed = changes.select(&:removed?)
      def changed = changes.select(&:changed?)
    end

    class Comparator
      def initialize(left_path, right_path)
        @left_path = left_path
        @right_path = right_path
      end

      def compare
        left = snapshot(@left_path)
        right = snapshot(@right_path)
        changes = diff_values(left, right)
        Result.new(
          differences: changes.map { format_change(_1) }.freeze,
          changes: changes.freeze
        )
      end

      private

      def snapshot(path)
        Mxrb.open(path) do |project|
          {
            project: {
              mendix_version: project.mendix_version,
              format_version: project.format_version
            },
            security: security_summary(project),
            navigation: normalize_hash(project.navigation.to_h),
            design_assets: design_asset_summary(project),
            units: unit_summary(project),
            modules: project.modules.sort_by(&:name).map { module_summary(_1) }
          }
        end
      end

      def design_asset_summary(project)
        root = File.dirname(project.mpr.path)
        Model::DesignSystem::ASSET_DIRECTORIES.flat_map do |directory|
          Dir.glob(File.join(root, directory, "**", "*"))
        end.select { File.file?(_1) && !File.symlink?(_1) }.sort.to_h do |path|
          relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
          [relative, Digest::SHA256.file(path).hexdigest]
        end
      end

      def security_summary(project)
        raw = project.all_units.find { project.parse_bson(_1)["$Type"] == "Security$ProjectSecurity" }
        return nil unless raw

        doc = project.parse_bson(raw)
        {
          security_level: doc["SecurityLevel"],
          check_security: doc["CheckSecurity"],
          admin_user_name: doc["AdminUserName"],
          admin_user_role: doc["AdminUserRole"],
          demo_users_enabled: doc["EnableDemoUsers"],
          guest_access_enabled: doc["EnableGuestAccess"],
          guest_user_role: doc["GuestUserRole"],
          sign_in_microflow: doc["SignInMicroflow"],
          password_policy: normalize_flow_value(doc["PasswordPolicySettings"], {}),
          user_roles: IO::BsonCodec.parse_array(doc["UserRoles"]).fetch(:items).map do |role|
            {
              name: role["Name"],
              admin: role["ManageAllRoles"] == true,
              module_roles: IO::BsonCodec.parse_array(role["ModuleRoles"]).fetch(:items).sort
            }
          end.sort_by { _1[:name].to_s }
        }
      end

      def unit_summary(project)
        project.all_units.map do |unit|
          next if unit["UnitID"] == unit["ContainerID"]

          doc = project.parse_bson(unit)
          {
            containment: unit["ContainmentName"].to_s,
            container_root: false,
            type: doc["$Type"].to_s,
            name: doc["Name"] || doc["name"] || ""
          }
        end.compact.sort_by { [_1[:containment], 1, _1[:type], _1[:name]] }
      end

      def module_summary(mod)
        {
          name: mod.name,
          entities: mod.entities.sort_by(&:name).map { entity_summary(_1) },
          associations: mod.associations.sort_by(&:name).map { association_summary(_1) },
          pages: mod.pages.sort_by(&:name).map { page_summary(_1) },
          menus: mod.menus.sort_by(&:name).map { menu_summary(_1) },
          module_roles: mod.module_roles.sort_by { _1[:name].to_s },
          microflows: mod.microflows.sort_by(&:name).map { flow_summary(_1) },
          nanoflows: mod.nanoflows.sort_by(&:name).map { flow_summary(_1) }
        }
      end

      def entity_summary(entity)
        {
          name: entity.name,
          documentation: entity.documentation.to_s,
          persistable: entity.persistable != false,
          generalization: normalize_generalization(entity.generalization),
          access_rules: Array(entity.access_rules).map { normalize_hash(_1) },
          attributes: entity.attributes.sort_by(&:name).map do |attribute|
            {
              name: attribute.name,
              documentation: attribute.documentation.to_s,
              type: attribute.type,
              default: attribute.default_value.to_s,
              native_type: normalize_flow_value(attribute.raw_type_doc, {}),
              native_value: normalize_flow_value(attribute.raw_value_doc, {})
            }
          end
        }
      end

      def association_summary(association)
        {
          name: association.name,
          type: association.association_type,
          owner: association.owner,
          storage_format: association.storage_format,
          documentation: association.documentation.to_s,
          delete_behavior: normalize_flow_value(association.delete_behavior, {})
        }
      end

      def page_summary(page)
        {
          name: page.name,
          title: page.title,
          layout: page.layout_id,
          allowed_roles: page.allowed_module_roles.sort,
          data_source: normalize_hash(page.data_source),
          widgets: page.widgets.map { widget_summary(_1) }
        }
      end

      def menu_summary(menu)
        {
          name: menu.name,
          items: menu.items.map { menu_item_summary(_1) }
        }
      end

      def menu_item_summary(item)
        {
          name: item[:caption],
          caption: item[:caption],
          page: item[:page],
          items: Array(item[:items]).map { menu_item_summary(_1) }
        }
      end

      def widget_summary(widget)
        {
          type: widget[:type],
          name: widget[:name],
          options: normalize_hash(widget.fetch(:options, {})),
          events: Array(widget[:events]).map { normalize_hash(_1) },
          children: Array(widget[:children]).map { widget_summary(_1) }
        }
      end

      def flow_summary(flow)
        ids = {}
        assign_flow_ids(flow.objects, flow.flows, ids)
        objects = flow.objects.sort_by { ids.fetch(_1["$ID"], ids.size) }
        normalized_flows = flow.flows.map do |edge|
          {
            origin: normalize_flow_value(edge["OriginPointer"], ids),
            destination: normalize_flow_value(edge["DestinationPointer"], ids),
            error_handler: edge["IsErrorHandler"] == true,
            cases: normalized_case_values(edge, ids)
          }
        end.sort_by { [_1[:origin].to_s, _1[:destination].to_s, _1[:error_handler].to_s, _1[:cases].to_s] }
        {
          name: flow.name,
          return_type: flow.return_type.to_s,
          allowed_roles: flow.allowed_module_roles.sort,
          parameters: flow.parameters.map { normalize_hash(_1) },
          body: {
            objects: objects.map { normalize_flow_value(_1, ids) },
            flows: normalized_flows
          }
        }
      end

      def normalize_flow_value(value, ids)
        return { object: ids.fetch(value) } if ids.key?(value)

        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            next if %w[
              $ID X Y RelativeMiddlePoint Size
              OriginBezierVector DestinationBezierVector
              OriginConnectionIndex DestinationConnectionIndex Line
            ].include?(key.to_s)
            next if key.to_s.end_with?("Model") &&
                    item.is_a?(Hash) && item["$Type"] == "Expressions$NoExpression"

            result[key.to_sym] = normalize_flow_value(item, ids)
          end
        when Array
          items = value
          if items.all? { _1.is_a?(Hash) && ids.key?(_1["$ID"]) }
            items = items.sort_by { ids.fetch(_1["$ID"]) }
          end
          items.map { normalize_flow_value(_1, ids) }
        else
          value
        end
      end

      def assign_flow_ids(objects, flows, ids)
        local_ids = objects.to_h { [_1["$ID"], true] }
        local_flows = flows.select do |edge|
          local_ids.key?(edge["OriginPointer"]) && local_ids.key?(edge["DestinationPointer"])
        end
        incoming = local_flows.group_by { _1["DestinationPointer"] }
        outgoing = local_flows.group_by { _1["OriginPointer"] }
        roots = objects.select { _1["$Type"] == "Microflows$StartEvent" }
        roots += objects.reject { incoming.key?(_1["$ID"]) || roots.include?(_1) }
        queue = roots
        until queue.empty?
          object = queue.shift
          next if ids.key?(object["$ID"])

          ids[object["$ID"]] = ids.size
          nested = object.dig("ObjectCollection", "Objects")
          assign_flow_ids(array_payload(nested), flows, ids) if nested
          edges = Array(outgoing[object["$ID"]]).sort_by do |edge|
            [edge["IsErrorHandler"] == true ? 1 : 0, normalized_case_values(edge, ids).to_s]
          end
          edges.each do |edge|
            target = objects.find { _1["$ID"] == edge["DestinationPointer"] }
            queue << target
          end
        end
        objects.each do |object|
          next if ids.key?(object["$ID"])

          ids[object["$ID"]] = ids.size
          nested = object.dig("ObjectCollection", "Objects")
          assign_flow_ids(array_payload(nested), flows, ids) if nested
        end
      end

      def normalized_case_values(edge, ids)
        values = if edge["CaseValues"]
          array_payload(edge["CaseValues"])
        elsif edge["NewCaseValue"]
          [edge["NewCaseValue"]]
        else
          []
        end
        values.filter_map do |value|
          next if value["$Type"].to_s.end_with?("$NoCase")

          normalize_flow_value(value.reject { |key, _| key == "$ID" }, ids)
        end
      end

      def array_payload(value)
        IO::BsonCodec.parse_array(value)[:items]
      rescue StandardError
        []
      end

      def diff_values(left, right, path = [])
        return [] if left == right

        if left.is_a?(Hash) && right.is_a?(Hash)
          keys = (left.keys + right.keys).uniq.sort_by(&:to_s)
          return keys.flat_map { diff_values(left[_1], right[_1], path + [_1]) }
        end

        if left.is_a?(Array) && right.is_a?(Array)
          return diff_named_arrays(left, right, path) if named_array?(left) && named_array?(right)

          max = [left.size, right.size].max
          return (0...max).flat_map { diff_values(left[_1], right[_1], path + [_1]) }
        end

        [Change.new(change_operation(left, right), path.freeze, left, right)]
      end

      def diff_named_arrays(left, right, path)
        left_by_name = left.to_h { [_1[:name], _1] }
        right_by_name = right.to_h { [_1[:name], _1] }
        common_names = (left_by_name.keys & right_by_name.keys).sort
        changes = common_names.flat_map do |name|
          diff_values(left_by_name[name], right_by_name[name], path + [name])
        end

        left_only = (left_by_name.keys - common_names).sort.map { left_by_name.fetch(_1) }
        right_only = (right_by_name.keys - common_names).sort.map { right_by_name.fetch(_1) }
        left_only.dup.each do |left_item|
          match = right_only.find { same_except_name?(left_item, _1) }
          next unless match

          changes.concat(diff_values(left_item, match, path + [left_item[:name]]))
          left_only.delete(left_item)
          right_only.delete(match)
        end

        changes.concat(left_only.flat_map { diff_values(_1, nil, path + [_1[:name]]) })
        changes.concat(right_only.flat_map { diff_values(nil, _1, path + [_1[:name]]) })
        changes
      end

      def named_array?(items)
        return false unless items.all? { _1.is_a?(Hash) && _1.key?(:name) }

        names = items.map { _1[:name] }
        names.uniq.size == names.size
      end

      def same_except_name?(left, right)
        left.reject { |key, _| key == :name } == right.reject { |key, _| key == :name }
      end

      def normalize_hash(value)
        return value unless value.is_a?(Hash)

        value.to_h do |key, item|
          normalized = if item.is_a?(Hash)
            normalize_hash(item)
          elsif item.is_a?(Array)
            item.map { _1.is_a?(Hash) ? normalize_hash(_1) : _1 }
          else
            item
          end
          [key.to_sym, normalized]
        end
      end

      def normalize_generalization(value)
        defaults = {
          Persistable: false, HasCreatedDateAttr: false, HasChangedDateAttr: false,
          HasOwnerAttr: false, HasChangedByAttr: false
        }
        defaults.merge(normalize_flow_value(value, {}))
      end

      def format_path(path)
        path.map { _1.is_a?(Integer) ? "[#{_1}]" : _1 }.join(".")
      end

      def change_operation(left, right)
        return :added if left.nil?
        return :removed if right.nil?

        :changed
      end

      def format_change(change)
        "#{format_path(change.path)}: #{change.before.inspect} != #{change.after.inspect}"
      end
    end
  end

  def self.compare(left_path, right_path)
    Compare::Comparator.new(left_path, right_path).compare
  end

  class << self
    alias diff compare
  end
end
