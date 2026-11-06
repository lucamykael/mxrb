# frozen_string_literal: true

require 'base64'
require 'json'

module Mxrb
  # The fields each element type stores in one project. Studio Pro stores every property
  # of an element, so a field that a type never carries in a project saved by Studio Pro
  # does not exist in that Mendix version. A rebuild of the same version removes such
  # fields, which the version-neutral writer would otherwise add, and stores a list under
  # the collection marker the project always uses for that field.
  class StoredFields
    IDENTITY = %w[$ID $Type].freeze
    # The writer follows these schemas exactly, and projects made by generators for them
    # may leave out fields the version has, so their stored fields prove nothing.
    WRITER_SCHEMAS = %w[10.24.0.73019 11.12.1].freeze
    private_constant :IDENTITY

    def self.applies_to?(version) = !WRITER_SCHEMAS.include?(version.to_s)

    def self.from(documents, version:, template_root: File.join(__dir__, 'templates', 'project'))
      fields = new
      documents.each { fields.learn(_1) }
      template = File.join(template_root, "#{version}.json")
      if File.file?(template)
        JSON.parse(File.read(template)).fetch('units', []).each do |unit|
          fields.learn(IO::BsonCodec.parse(Base64.strict_decode64(unit.fetch('contents'))))
        end
      end
      fields
    end

    def initialize
      @fields = Hash.new { |hash, type| hash[type] = Set.new(IDENTITY) }
      @markers = Hash.new { |hash, field| hash[field] = Set.new }
    end

    def learn(value)
      case value
      when Hash
        learn_fields(value) if value['$Type'].is_a?(String)
        value.each_value { learn(_1) }
      when Array then value.each { learn(_1) }
      end
      self
    end

    # Removes, in place, the fields a known type never stores and restores the markers it
    # always uses. Returns whether anything changed.
    def project!(value)
      case value
      when Hash then [remove_unknown!(value), *value.each_value.map { project!(_1) }].any?
      when Array then value.map { project!(_1) }.any?
      else false
      end
    end

    private

    def learn_fields(document)
      type = document['$Type']
      @fields[type].merge(document.keys)
      document.each do |key, entry|
        @markers[[type, key]] << entry.first if entry.is_a?(Array) && entry.first.is_a?(Integer)
      end
    end

    def remove_unknown!(document)
      type = document['$Type']
      return false unless type.is_a?(String) && @fields.key?(type)

      unknown = document.keys - @fields[type].to_a
      unknown.each { document.delete(_1) }
      [unknown.any?, *document.map { |key, entry| stored_marker!(type, key, entry) }].any?
    end

    def stored_marker!(type, key, entry)
      markers = @markers.fetch([type, key], nil)
      return false unless markers&.one? && entry.is_a?(Array) && entry.first.is_a?(Integer)
      return false if entry.first == markers.first

      entry[0] = markers.first
      true
    end
  end
end
