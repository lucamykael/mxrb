# frozen_string_literal: true

require_relative 'tfidf_embedder'
require_relative 'onnx_embedder'

module Mxrb
  module Semantic
    RankedArtifact = Data.define(:artifact, :similarity, :distance)

    # Builds optional embedding backends and ranks artifacts in pure Ruby.
    module Embedder
      module_function

      def build(backend: :auto)
        case backend
        when :tfidf then TfidfEmbedder.new
        when :onnx  then OnnxEmbedder.new
        when :auto  then OnnxEmbedder.available? ? OnnxEmbedder.new : TfidfEmbedder.new
        else raise ArgumentError, "unknown embedding backend: #{backend.inspect}"
        end
      end

      def artifact_text(artifact)
        metadata = artifact.metadata || {}
        [
          artifact.qualified_name, artifact.name, artifact.kind,
          artifact.module_name, metadata[:documentation]
        ].compact.join(' ')
      end

      def rank(artifacts, query, embedder:, limit:)
        rank_with_distance(artifacts, query, embedder:, limit:).map(&:artifact).freeze
      end

      def rank_with_distance(artifacts, query, embedder:, limit:)
        query_vector = embedder.embed(query.to_s)
        scored = artifacts.map do |artifact|
          similarity = dot(query_vector, embedder.embed(artifact_text(artifact)))
          RankedArtifact.new(artifact, similarity, 1.0 - similarity)
        end
        scored.sort_by { [-_1.similarity, _1.artifact.qualified_name] }.first(limit).freeze
      end

      def dot(left, right)
        raise ArgumentError, 'embedding dimensions do not match' unless left.size == right.size

        left.each_index.sum { left[_1] * right[_1] }
      end
    end
  end
end
