# frozen_string_literal: true

module Mxrb
  module Semantic
    # Optional sentence-transformer backend powered by the informers gem.
    class OnnxEmbedder
      MODEL = 'sentence-transformers/all-MiniLM-L6-v2'

      def self.available?
        require 'informers'
        true
      rescue LoadError
        false
      end

      def initialize(pipeline: nil)
        require 'informers' unless pipeline
        @pipeline = pipeline || Informers.pipeline(
          'embedding', MODEL
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
