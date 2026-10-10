# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Runtime inheritance is independent of source identity: inherited members
    # are stored on each concrete entity without duplicating public declarations.
    module RecordInheritance
      FILE_ATTRIBUTES = [
        { name: :name, mendix_name: 'Name', type: :string, default: '' },
        { name: :file_size, mendix_name: 'FileSize', type: :long, default: 0 },
        { name: :has_contents, mendix_name: 'HasContents', type: :boolean, default: false }
      ].freeze

      def runtime_ancestors
        names = []
        target = generalization&.fetch(:target)
        while target
          raise ArgumentError, "cyclic entity generalization: #{mendix_name}" if
            target == mendix_name || names.include?(target)

          names << target
          target = runtime_parent(target)
        end
        names
      end

      def runtime_parent(name)
        parent = Registry.fetch(:record, name)
        return parent.generalization&.fetch(:target) if parent

        'System.FileDocument' if name == 'System.Image'
      end

      def runtime_attributes
        inherited = runtime_ancestors.reverse.flat_map do |name|
          parent = Registry.fetch(:record, name)
          if parent
            Array(parent.attributes)
          else
            name == 'System.FileDocument' ? FILE_ATTRIBUTES : Runtime::SystemDomain.record_attributes(name)
          end
        end
        (inherited + Array(attributes)).reverse.uniq { _1.fetch(:mendix_name) }.reverse
      end

      def runtime_file_policy
        ancestors = runtime_ancestors
        policy = ancestors.reverse.reduce({}) do |result, name|
          result.merge(Registry.fetch(:record, name)&.file_upload_policy || {})
        end.merge(file_upload_policy)
        policy[:images_only] = true if mendix_name == 'System.Image' || ancestors.include?('System.Image')
        policy
      end
    end
  end
end
