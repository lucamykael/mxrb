# frozen_string_literal: true

module Mxrb
  module Semantic
    # Optional sentence-transformer backend powered by the informers gem.
    class OnnxEmbedder
      MODEL = 'sentence-transformers/all-MiniLM-L6-v2'
      MODEL_REVISION = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'

      def self.available?
        require 'informers'
        true
      rescue LoadError
        false
      end

      def initialize(pipeline: nil)
        require 'informers' unless pipeline
        @pipeline = pipeline || Informers.pipeline(
          'embedding', MODEL, revision: MODEL_REVISION
        )
        @dimension = nil
      end

      def backend = :onnx
      def dimension = (@dimension ||= embed('warmup').size)

      def embed(text)
        vector = @pipeline.call(text)
        vector.first.is_a?(Array) ? vector.first : vector
      end
    end
  end
end
