# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Exposes only the existing semantic source DSL to runtime widget trees,
    # without mixing in the native widget-building methods themselves.
    # Schema-specific guards below deliberately remain explicit; equivalence
    # is checked against the existing DSL instead of guessing at extensions.
    # rubocop:disable Metrics
    module PageDataSources
      METHODS = %i[context association microflow_source nanoflow_source listen_to page_variable].freeze
      METHODS.each do |name|
        define_method(name) do |*arguments, **options|
          Dsl::WidgetSlotBuilder.new.public_send(name, *arguments, **options)
        end
      end

      Expression = Data.define(:source, :value)
      private_constant :METHODS, :Expression

      class << self
        # nil means retain the original hash, including unknown fields and
        # explicit nil/false that the legacy DSL deliberately compacts.
        def source_expression(source)
          return unless source.is_a?(Hash)

          expression = semantic_expression(source)
          expression.source if expression && normalize(expression.value) == source
        rescue ArgumentError, TypeError, KeyError
          nil
        end

        # Page.configure receives the original Ruby semantic source, unlike
        # the JSON widget projection. Preserve symbol/string representation
        # exactly rather than assuming JSON equivalence is sufficient.
        def configuration_expression(source)
          return unless source.is_a?(Hash)

          expression = semantic_expression(normalize(source))
          expression.source if expression && expression.value == source
        rescue ArgumentError, TypeError, KeyError
          nil
        end

        def variable_reference_expression(variable)
          variable_expression(variable)&.source
        rescue ArgumentError, TypeError, KeyError
          nil
        end

        private

        def semantic_expression(source)
          case source['kind']
          when 'context' then context_expression(source)
          when 'association' then association_expression(source)
          when 'microflow', 'nanoflow' then flow_expression(source)
          when 'listen' then listen_expression(source)
          end
        end

        def expression(method, arguments, keywords = {})
          args = arguments.map { _1.is_a?(Expression) ? _1.source : _1.inspect }
          args.concat(keywords.map { |key, value| "#{key}: #{value.is_a?(Expression) ? value.source : value.inspect}" })
          values = arguments.map { _1.is_a?(Expression) ? _1.value : _1 }
          options = keywords.transform_values { _1.is_a?(Expression) ? _1.value : _1 }
          Expression.new(
            source: "#{method}(#{args.join(', ')})",
            value: Dsl::WidgetSlotBuilder.new.public_send(method, *values, **options)
          )
        end

        def variable_expression(variable)
          return unless variable.is_a?(Hash)
          return unless keys?(variable, %w[kind name sub_key use_all_pages])
          return unless variable['kind'].is_a?(String)

          options = { kind: variable.fetch('kind').to_sym }
          %w[sub_key use_all_pages].each { |key| options[key.to_sym] = variable[key] if variable.key?(key) }
          result = expression(:page_variable, [variable['name']], options)
          result if normalize(result.value) == variable
        end

        def context_expression(source)
          return unless keys?(source, %w[kind entity variable force_full_objects])
          return unless source['entity'].is_a?(String) && !source['entity'].empty?

          options = { entity: source.fetch('entity') }
          name = nil
          if source.key?('variable')
            variable = source.fetch('variable')
            return unless variable_expression(variable)

            name = variable['name']
            %w[kind sub_key use_all_pages].each { |key| options[key.to_sym] = variable[key] if variable.key?(key) }
            options[:kind] = options[:kind].to_sym
          end
          options[:force_full_objects] = source['force_full_objects'] if source.key?('force_full_objects')
          expression(:context, name.nil? ? [] : [name], options)
        end

        def association_expression(source)
          return unless keys?(source, %w[kind entity steps variable force_full_objects])
          return unless source['entity'].is_a?(String) && source['steps'].is_a?(Array)
          return unless source['steps'].all? do |step|
            step.is_a?(Hash) && step.keys.sort == %w[association entity] &&
            step.values.all? { _1.is_a?(String) && !_1.empty? }
          end

          steps = source.fetch('steps').map { [_1.fetch('association'), _1.fetch('entity')] }
          options = { entity: source.fetch('entity') }
          if source.key?('variable')
            options[:from] = variable_expression(source['variable'])
            return unless options[:from]
          end
          options[:force_full_objects] = source['force_full_objects'] if source.key?('force_full_objects')
          expression(:association, [steps], options)
        end

        def flow_expression(source)
          return unless keys?(source, %w[kind name mappings force_full_objects settings_native])
          return unless source['name'].is_a?(String) && !source['name'].empty?

          options = {}
          if source.key?('mappings')
            mappings = source.fetch('mappings')
            return unless mappings.is_a?(Array)

            pairs = mappings.map { mapping_expression(_1) }
            return if pairs.any?(&:nil?)

            options[:pass] = Expression.new(
              source: "[#{pairs.map(&:source).join(', ')}]", value: pairs.map(&:value)
            )
          end
          if source.key?('settings_native')
            settings = source.fetch('settings_native')
            return unless source['kind'] == 'microflow' && settings.is_a?(Hash) &&
                          settings.keys == ['UseAllPages'] && [true, false].include?(settings['UseAllPages'])

            options[:use_all_pages] = settings.fetch('UseAllPages')
          end
          options[:force_full_objects] = source['force_full_objects'] if source.key?('force_full_objects')
          expression("#{source.fetch('kind')}_source", [source.fetch('name')], options)
        end

        def mapping_expression(mapping)
          return unless mapping.is_a?(Hash) && mapping['parameter'].is_a?(String)

          value = if mapping.keys.sort == %w[expression parameter] && mapping['expression'].is_a?(String)
                    Expression.new(source: mapping.fetch('expression').inspect, value: mapping.fetch('expression'))
                  elsif mapping.keys.sort == %w[parameter variable]
                    variable_expression(mapping['variable'])
                  end
          return unless value

          Expression.new(source: "[#{mapping.fetch('parameter').inspect}, #{value.source}]",
                         value: [mapping.fetch('parameter'), value.value])
        end

        def listen_expression(source)
          return unless keys?(source, %w[kind target force_full_objects])
          return unless source['target'].is_a?(String) && !source['target'].empty?

          options = source.key?('force_full_objects') ? { force_full_objects: source['force_full_objects'] } : {}
          expression(:listen_to, [source.fetch('target')], options)
        end

        def keys?(value, allowed) = (value.keys - allowed).empty?

        def normalize(value)
          case value
          when Hash then value.to_h { |key, item| [key.to_s, normalize(item)] }
          when Array then value.map { normalize(_1) }
          when Symbol then value.to_s
          else value
          end
        end
      end
    end
    # rubocop:enable Metrics
  end
end
