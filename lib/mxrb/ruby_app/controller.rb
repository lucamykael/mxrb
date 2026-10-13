# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Application-owned HTTP controller. Routes remain declared by published
    # REST endpoints; controllers receive actions and use these typed CRUD helpers.
    class Controller
      class << self
        attr_reader :registered_name

        def controller_name(name)
          value = name.to_s
          raise ArgumentError, 'controller name cannot be empty' if value.empty?

          @registered_name = value
          Registry.register(:controller, value, self)
        end
      end

      attr_reader :application, :context

      def initialize(application, context: nil)
        @application = application
        @context = context
      end

      def all(model)
        application.records(entity_name(model), context:)
      end

      def find(model, id)
        application.record(entity_name(model), id, context:)
      end

      def find!(model, id)
        find(model, id) || raise(NotFoundError, "#{entity_name(model)} #{id} not found")
      end

      def find_by(model, **attributes)
        expected = mendix_attributes(model, attributes)
        all(model).find do |record|
          members = record.fetch(:attributes)
          expected.all? do |name, value|
            actual = members[name]
            actual == value || (!actual.nil? && !value.nil? && actual.to_s == value.to_s)
          end
        end
      end

      def find_by!(model, **attributes)
        find_by(model, **attributes) ||
          raise(NotFoundError, "#{entity_name(model)} matching #{attributes.keys.join(', ')} not found")
      end

      def create(model, attributes = nil, **values)
        attributes = values if attributes.nil?
        application.create_record(
          entity_name(model), mendix_attributes(model, attributes), context:
        )
      end

      def update(model, id, attributes = nil, **values)
        attributes = values if attributes.nil?
        result = application.update_record(
          entity_name(model), id, mendix_attributes(model, attributes), context:
        )
        result || raise(NotFoundError, "#{entity_name(model)} #{id} not found")
      end

      def destroy(model, id)
        deleted = application.delete_record(entity_name(model), id, context:)
        raise NotFoundError, "#{entity_name(model)} #{id} not found" unless deleted

        true
      end

      def update_by(model, attribute:, value:, **attributes)
        record = find_by!(model, attribute => value)
        update(model, record.fetch(:id), attributes)
      end

      def destroy_by(model, attribute:, value:)
        record = find_by!(model, attribute => value)
        destroy(model, record.fetch(:id))
      end

      def model(name)
        Registry.fetch(:record, name.to_s) ||
          raise(ValidationError, "model #{name} is not registered")
      end

      private

      def entity_name(model)
        return model.mendix_name if model.is_a?(Class) && model <= Record

        raise ArgumentError, 'CRUD helpers require an Mxrb::RubyApp::Record class'
      end

      def mendix_attributes(model, attributes)
        attributes.to_h.to_h do |name, value|
          member = model.attributes.find do |candidate|
            [candidate.fetch(:name), candidate.fetch(:mendix_name)].map(&:to_s).include?(name.to_s)
          end
          raise ArgumentError, "unknown #{model.mendix_name} attribute #{name}" unless member

          [member.fetch(:mendix_name), value]
        end
      end
    end
  end
end
