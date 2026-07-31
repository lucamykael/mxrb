# frozen_string_literal: true

module Mxrb
  module Semantic
    # Deterministic hashed term-frequency embeddings with unit normalization.
    class TfidfEmbedder
      DIM = 512

      def dimension = DIM
      def backend = :tfidf

      def embed(text)
        tokens = tokenize(text)
        return Array.new(DIM, 0.0) if tokens.empty?

        freq = tokens.tally
        total = tokens.size.to_f
        vec = Array.new(DIM, 0.0)
        freq.each { |term, count| vec[bucket(term)] += count / total }
        normalize(vec)
      end

      private

      # FNV-1a 32-bit — deterministic across Ruby versions and RUBY_HASH_SEED
      def fnv32(str)
        h = 0x811c9dc5
        str.each_byte { |b| h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF }
        h
      end

      def bucket(term) = fnv32(term) % DIM

      def tokenize(text)
        text.downcase.scan(/[a-z][a-z0-9]*/).reject { _1.length < 2 }
      end

      def normalize(vec)
        norm = Math.sqrt(vec.sum { _1**2 })
        return vec if norm.zero?

        vec.map { _1 / norm }
      end
    end
  end
end
