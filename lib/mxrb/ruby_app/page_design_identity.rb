# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Runtime projection identities only. The existing manifest owns IDs;
    # authored design keys/options and ordering remain authoritative. This
    # does not turn Page.configure into a native Mendix page declaration.
    class PageDesignIdentity # rubocop:disable Metrics/ClassLength
      THREAD_KEY = :mxrb_ruby_app_page_design_identity

      def self.with(manifest)
        previous = Thread.current[THREAD_KEY]
        context = new(manifest)
        Thread.current[THREAD_KEY] = context
        result = yield
        context.finalize!
        result
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def self.restore(page_id, widgets)
        context = Thread.current[THREAD_KEY]
        context ? context.restore(page_id, widgets) : widgets
      end

      def self.configure(owner, widgets)
        context = Thread.current[THREAD_KEY]
        context ? context.configure(owner, widgets) : widgets
      end

      def initialize(manifest)
        @pages = {}
        @pending = {}
        manifest.modules.each do |mod|
          Array(mod['pages']).each do |page|
            id = page.fetch('id').to_s
            raise ValidationError, 'duplicate private page identity' if @pages.key?(id)

            @pages[id] = page['widgets']
          end
        end
      end

      def configure(owner, widgets)
        if owner.mendix_id.to_s.empty?
          @pending[owner] = widgets
          return widgets
        end

        restored = restore(owner.mendix_id, widgets)
        @pending.delete(owner)
        restored
      end

      def finalize!
        @pending.each do |owner, widgets|
          owner.instance_variable_set(:@widgets, restore(owner.mendix_id, widgets).freeze)
        end
      end

      def restore(page_id, widgets) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return widgets unless @pages.key?(page_id.to_s)

        baseline = @pages.fetch(page_id.to_s)
        index = Hash.new { |hash, key| hash[key] = [] }
        walk(baseline) { |widget| index[widget_key(widget)] << widget } if baseline.is_a?(Array)
        transform(widgets) do |widget|
          properties = widget.fetch('options', {})['design_properties']
          next widget unless properties.is_a?(Array) && properties.any? { semantic_property?(_1) }

          unless baseline.is_a?(Array)
            raise ValidationError, 'existing page requires its private widget identity baseline'
          end

          candidates = index.fetch(widget_key(widget), [])
          unless candidates.one?
            raise ValidationError, 'cannot resolve design properties for a renamed, new or ambiguous page widget'
          end

          previous = candidates.first.fetch('options', {}).fetch('design_properties', [])
          widget['options']['design_properties'] = resolve_properties(previous, properties)
          widget
        end
      end

      private

      def widget?(value)
        value.is_a?(Hash) && value['type'] == 'data_view' && value['name'].is_a?(String) &&
          value['options'].is_a?(Hash)
      end

      def widget_key(widget) = [widget.fetch('type'), widget.fetch('name')]

      def walk(value, &block)
        case value
        when Array then value.each { walk(_1, &block) }
        when Hash
          yield value if widget?(value)
          value.each_value { walk(_1, &block) }
        end
      end

      def transform(value, &block)
        case value
        when Array then value.map { transform(_1, &block) }
        when Hash
          result = value.to_h { |key, child| [key, transform(child, &block)] }
          widget?(result) ? yield(result) : result
        else value
        end
      end

      def semantic_property?(value)
        value.is_a?(Hash) && value.key?('key') && value.key?('option')
      end

      def resolve_properties(previous, declarations) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        known = Array(previous).select { semantic_property?(_1) }
        authored = declarations.select { semantic_property?(_1) }
        assert_unique!(known, 'key')
        assert_unique!(authored, 'key')
        assert_unique!(known, 'id')
        assert_unique!(authored, 'id')
        by_key = known.to_h { [_1.fetch('key'), _1] }
        by_id = known.reject { _1['id'].to_s.empty? }.to_h { [_1.fetch('id'), _1] }
        used = []
        unmatched = []
        result = declarations.map do |declaration|
          next declaration unless semantic_property?(declaration)

          prior = by_key[declaration.fetch('key')] || by_id[declaration['id']]
          unless prior
            unmatched << declaration
            next declaration
          end
          raise ValidationError, 'duplicate design property identity claim' if used.include?(prior)

          used << prior
          declaration.merge(
            'id' => identity(declaration['id'], prior['id']),
            'value_id' => identity(declaration['value_id'], prior['value_id'])
          )
        end
        if unmatched.any? && (known - used).any?
          raise ValidationError,
                'cannot distinguish design property rename from removal/insertion; preserve its legacy id'
        end

        result
      end

      def assert_unique!(properties, field)
        values = properties.map { _1[field] }.reject { _1.to_s.empty? }
        return if values.uniq.size == values.size

        raise ValidationError, "duplicate design property #{field}"
      end

      def identity(explicit, prior)
        raise ValidationError, 'missing private design property identity' if prior.to_s.empty?
        if !explicit.to_s.empty? && explicit.to_s != prior.to_s
          raise ValidationError, 'design property identity mismatch'
        end

        prior
      end
    end
  end
end
