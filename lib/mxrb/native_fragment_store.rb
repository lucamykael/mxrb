# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'errors'
require_relative 'io/bson_codec'

module Mxrb
  # Content-addressed storage for native model fragments that have no concise
  # typed DSL representation yet.
  class NativeFragmentStore # rubocop:disable Metrics/ClassLength
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
    THREAD_KEY = :mxrb_native_fragment_store

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      @mutex = Mutex.new
    end

    def put(document)
      raise ArgumentError, 'native fragment must be a Hash' unless document.is_a?(Hash)

      payload = IO::BsonCodec.serialize(document)
      digest = Digest::SHA256.hexdigest(payload)
      path = fragment_path(digest)
      @mutex.synchronize { persist(path, payload, digest) }
      digest
    end

    def fetch(digest, types: [], hints: [], overrides: {})
      path = fragment_path(digest)
      raise ValidationError, "native fragment #{digest} does not exist" unless File.file?(path)

      payload = File.binread(path)
      verify_payload!(payload, digest)
      document = IO::BsonCodec.parse(payload)
      raise ValidationError, "native fragment #{digest} is not a document" unless document.is_a?(Hash)

      validate_types!(document, types, digest)
      validate_hints!(document, hints, digest)
      apply_overrides(document, overrides, digest)
    end

    def self.current = Thread.current[THREAD_KEY]

    def self.with(store)
      previous = current
      Thread.current[THREAD_KEY] = store
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    private

    def fragment_path(digest)
      normalized = digest.to_s
      raise ValidationError, "invalid native fragment digest #{digest.inspect}" unless
        normalized.match?(DIGEST_PATTERN)

      File.join(root, "#{normalized}.bson")
    end

    def persist(path, payload, digest)
      if File.file?(path)
        verify_payload!(File.binread(path), digest)
        return
      end

      FileUtils.mkdir_p(root)
      temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.binwrite(temporary, payload)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end

    def verify_payload!(payload, digest)
      actual = Digest::SHA256.hexdigest(payload)
      return if actual == digest.to_s

      raise ValidationError,
            "native fragment digest mismatch: expected #{digest}, got #{actual}"
    end

    def validate_types!(document, expected, digest)
      missing = Array(expected).map(&:to_s).uniq - fragment_types(document)
      return if missing.empty?

      raise ValidationError,
            "native fragment #{digest} is missing declared type(s): #{missing.join(', ')}"
    end

    def fragment_types(value, found = [])
      case value
      when Hash
        found << value['$Type'].to_s unless value['$Type'].to_s.empty?
        value.each_value { fragment_types(_1, found) }
      when Array
        value.each { fragment_types(_1, found) }
      end
      found.uniq
    end

    def validate_hints!(document, expected, digest)
      missing = Array(expected).map(&:to_s).uniq - fragment_hints(document)
      return if missing.empty?

      raise ValidationError,
            "native fragment #{digest} is missing declared hint(s): #{missing.join(', ')}"
    end

    def fragment_hints(value, found = [])
      case value
      when Hash
        value.each { collect_fragment_hint(_1, _2, found) }
      when Array
        value.each { fragment_hints(_1, found) }
      end
      found.uniq
    end

    def collect_fragment_hint(key, child, found)
      found << child if key.to_s.match?(/(?:url|uri|endpoint|host)\z/i) &&
                        child.is_a?(String) && child.bytesize.between?(1, 512)
      fragment_hints(child, found)
    end

    def apply_overrides(document, overrides, digest)
      raise ValidationError, "native fragment #{digest} overrides must be a Hash" unless
        overrides.is_a?(Hash)

      overrides.each do |key, value|
        name = key.to_s
        unless document.key?(name) && scalar?(document.fetch(name)) && scalar?(value)
          raise ValidationError, "invalid native fragment override #{name.inspect} for #{digest}"
        end

        document[name] = value
      end
      document
    end

    def scalar?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Numeric) ||
        value == true || value == false
    end
  end

  # Resolves native fragments only while a configured DSL source is evaluated.
  module NativeFragmentAccess
    def native_fragment(digest, types: [], hints: [], overrides: {})
      store = NativeFragmentStore.current
      raise ValidationError, 'native fragment store is not configured' unless store

      store.fetch(digest, types:, hints:, overrides:)
    end
  end

  # Configures fragment resolution for the root project evaluator.
  module NativeFragmentEvaluation
    include NativeFragmentAccess

    def native_fragments(path)
      @native_fragment_store = NativeFragmentStore.new(path)
    end

    def evaluate(path)
      return instance_eval(File.read(path), path, 1) unless @native_fragment_store

      NativeFragmentStore.with(@native_fragment_store) do
        instance_eval(File.read(path), path, 1)
      end
    end

    def evaluate_dir(dir)
      return unless File.directory?(dir)

      Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
    end
  end
end
