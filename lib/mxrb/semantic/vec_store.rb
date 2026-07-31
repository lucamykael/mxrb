# frozen_string_literal: true

require 'json'
require_relative 'embedder'

module Mxrb
  module Semantic
    # Manages the _MxrbVecIndex virtual table (sqlite-vec) inside an .mpr file.
    # Optional: if the sqlite-vec gem is not installed this object is never created
    # and Index falls back to regex search transparently.
    class VecStore
      META_TABLE = '_MxrbVecMeta'
      VEC_TABLE = '_MxrbVecIndex'

      def self.available?
        require 'sqlite_vec'
        true
      rescue LoadError
        false
      end

      def initialize(mpr, embedder:, fingerprint:)
        @mpr = mpr
        @embedder = embedder
        @fingerprint = fingerprint
        mpr.load_vec_extension!
        ensure_tables!
      end

      def backend   = @embedder.backend
      def dimension = @embedder.dimension

      # Replaces all vectors and marks the table with its source fingerprint.
      def rebuild!(artifacts)
        @mpr.vec_drop_index!(VEC_TABLE, META_TABLE)
        ensure_tables!
        @mpr.vec_transaction do
          artifacts.each { upsert(_1.id, Embedder.artifact_text(_1)) }
          @mpr.write_vec_meta!(META_TABLE, backend.to_s, dimension, @fingerprint)
        end
        self
      end

      # K-nearest-neighbour search. Returns [{id:, distance:}] sorted by distance.
      def search(query, limit: 10)
        vec = @embedder.embed(query)
        json = JSON.generate(vec)
        @mpr.vec_knn(VEC_TABLE, json, limit)
      end

      # True when vectors represent this exact model and embedding backend.
      def compatible?
        stored = @mpr.vec_meta(META_TABLE)
        return false unless stored

        stored == {
          backend: backend.to_s, dimension:, fingerprint: @fingerprint
        }
      end

      private

      def ensure_tables!
        @mpr.ensure_vec_table!(VEC_TABLE, dimension)
        @mpr.ensure_vec_meta_table!(META_TABLE)
      end

      def upsert(id, text)
        vec = @embedder.embed(text)
        json = JSON.generate(vec)
        @mpr.vec_upsert(VEC_TABLE, id, json)
      end
    end
  end
end
