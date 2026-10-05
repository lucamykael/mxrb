# frozen_string_literal: true

module Mxrb
  class Exporter
    # Emits page-variable options and conditional UI policies as editable Ruby.
    module DataSourceOptions
      private

      def data_view_pass_ruby(mappings)
        values = Array(mappings)
        return if values.empty?

        pairs = values.map { data_view_mapping_ruby(_1) }
        "{ #{pairs.join(', ')} }"
      end

      def data_view_mapping_ruby(mapping)
        mapping = mapping.transform_keys(&:to_sym)
        value = mapping[:variable] ? page_variable_ruby(mapping[:variable]) : ruby(mapping[:expression])
        "#{symbol(mapping.fetch(:parameter))} => #{value}"
      end

      def page_variable_ruby(raw_variable)
        variable = raw_variable.transform_keys(&:to_sym)
        args = [variable[:name] ? symbol(variable[:name]) : 'nil'] + variable_ruby_options(variable)
        args << 'use_all_pages: true' if variable[:use_all_pages] == true
        args << "native: #{native_ruby(variable[:unknown_native])}" unless variable.fetch(:unknown_native, {}).empty?
        "page_variable(#{args.join(', ')})"
      end

      def variable_ruby_options(variable)
        args = []
        args << "kind: #{symbol(variable[:kind])}" if variable.fetch(:kind, :page_parameter).to_sym != :page_parameter
        args << "sub_key: #{ruby(variable[:sub_key])}" if variable[:sub_key]
        args
      end

      def data_view_condition_ruby(method, raw_condition, indent)
        return [] unless raw_condition

        condition = raw_condition.transform_keys(&:to_sym)
        args = data_view_condition_arguments(condition, indent) + data_view_condition_policy(condition, indent)
        [(' ' * indent) + "#{method} #{args.join(', ')}"]
      end

      def data_view_condition_arguments(condition, indent)
        args = []
        args << ruby(condition[:expression]) if condition[:expression]
        args << "roles: #{ruby(Array(condition[:roles]))}" unless Array(condition[:roles]).empty?
        args + data_view_condition_bindings(condition, indent)
      end

      def data_view_condition_bindings(condition, indent)
        args = []
        args << "attribute: #{ruby(condition[:attribute])}" if condition[:attribute]
        args << "conditions: #{native_ruby(condition[:conditions], indent)}" unless Array(condition[:conditions]).empty?
        args
      end

      def data_view_condition_policy(condition, indent)
        args = []
        args << 'ignore_security: true' if condition[:ignore_security] == true
        args << "source: #{page_variable_ruby(condition[:source_variable])}" if condition[:source_variable]
        unless condition.fetch(:unknown_native, {}).empty?
          args << "native: #{native_ruby(condition[:unknown_native], indent)}"
        end
        args
      end
    end

    # Emits context, association, flow and grid-selection data sources.
    module DataSources
      include DataSourceOptions

      private

      def data_view_source_ruby(raw_source)
        source = raw_source.transform_keys(&:to_sym)
        return complex_data_view_source_ruby(source) if complex_data_view_source?(source)

        simple_data_view_source_ruby(source, data_view_common_arguments(source))
      end

      def data_view_common_arguments(source)
        args = []
        args << 'force_full_objects: true' if source[:force_full_objects] == true
        args << "native: #{native_ruby(source[:unknown_native])}" unless source.fetch(:unknown_native, {}).empty?
        args
      end

      def simple_data_view_source_ruby(source, common)
        kind = source.fetch(:kind).to_sym
        case kind
        when :context then "context(#{(context_source_arguments(source) + common).join(', ')})"
        when :association then "association(#{(association_source_arguments(source) + common).join(', ')})"
        when :microflow, :nanoflow then "#{kind}_source(#{(flow_source_arguments(source) + common).join(', ')})"
        when :listen then "listen_to(#{([symbol(source.fetch(:target))] + common).join(', ')})"
        else complex_data_view_source_ruby(source)
        end
      end

      def context_source_arguments(source)
        variable = source[:variable]&.transform_keys(&:to_sym)
        args = []
        args << symbol(variable[:name]) if variable&.fetch(:name, nil)
        args << "entity: #{ruby(source.fetch(:entity))}"
        args.concat(variable_ruby_options(variable)) if variable
        args << 'use_all_pages: true' if variable&.fetch(:use_all_pages, false)
        args
      end

      def association_source_arguments(source)
        args = [association_source_steps(Array(source[:steps])), "entity: #{ruby(source.fetch(:entity))}"]
        args << "from: #{page_variable_ruby(source[:variable])}" if source[:variable]
        args
      end

      def association_source_steps(steps)
        return ruby(steps.first[:association] || steps.first['association']) if steps.one?

        native_ruby(steps.map { |step| [step[:association], step[:entity]] })
      end

      def flow_source_arguments(source)
        args = [reference(source.fetch(:name))]
        pass = data_view_pass_ruby(source[:mappings])
        args << "pass: #{pass}" if pass
        args
      end

      def complex_data_view_source?(source)
        return true if source[:settings_native] || source[:entity_ref_native]

        Array(source[:mappings]).any? { _1[:unknown_native] || _1['unknown_native'] }
      end

      def complex_data_view_source_ruby(source)
        kind = source.fetch(:kind).to_sym
        options = source.reject { |key, _value| key == :kind }
        "view_source(#{symbol(kind)}, **#{native_ruby(options)})"
      end
    end
  end
end
