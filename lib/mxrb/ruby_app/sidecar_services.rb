# frozen_string_literal: true

require 'base64'

module Mxrb
  module RubyApp
    # What the Java actions sidecar asks of the application beyond its objects:
    # the metamodel behind Core.getMetaObjects and the microflow API, enumeration
    # captions, and the contents a Java action stores in a file document.
    class SidecarServices
      def initialize(project)
        @project = project
      end

      def metamodel
        model = Metamodel.new(@project)
        { 'objects' => model.objects, 'associations' => model.associations, 'microflows' => model.microflows }
      end

      # A value's caption in a language, '' when it has none there, as the Runtime
      # answers; without a language, the caption in the first language declared.
      def caption(enumeration, value, language)
        implementation = Registry.fetch(:enumeration, enumeration)
        return system_caption(enumeration, value) unless implementation

        captions = implementation.values.find { _1.fetch(:name) == value }&.fetch(:captions) || {}
        language.nil? ? captions.values.first.to_s : captions.fetch(language, '')
      end

      # Core.storeFileDocumentContent: the contents, the name, and the members
      # a file document reports for them.
      def store_file(store, object, name, bytes)
        file = FileContent.new(store.database).write(object.entity, object.id, name, Base64.strict_encode64(bytes))
        object.members.merge!('Name' => file.fetch(:name), 'HasContents' => true, 'Size' => file.fetch(:size))
        store.touch(object)
      end

      private

      def system_caption(enumeration, value)
        values = Metamodel::SYSTEM_ENUMERATIONS.fetch(enumeration, [])
        values.find { _1.fetch('id') == value }&.fetch('caption').to_s
      end
    end
  end
end
