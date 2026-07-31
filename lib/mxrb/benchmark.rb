# frozen_string_literal: true

module Mxrb
  BenchmarkResult = Data.define(:iterations, :open_seconds, :index_seconds, :validate_seconds, :units)

  # Repeatable wall-clock benchmark for the main read-only MPR operations.
  class Benchmark
    def initialize(path, iterations: 3, clock: Process.method(:clock_gettime))
      @path = File.expand_path(path)
      @iterations = Integer(iterations)
      @clock = clock
      raise ArgumentError, 'iterations must be between 1 and 100' unless (1..100).cover?(@iterations)
    end

    def run
      open_time, units = measure { Mxrb.open(@path) { _1.all_units.size } }
      index_time, = measure { Mxrb.open(@path) { _1.semantic_index.artifacts.size } }
      validate_time, = measure { Mxrb.validate(@path).valid? }
      BenchmarkResult.new(@iterations, open_time, index_time, validate_time, units)
    end

    private

    def measure
      value = nil
      started = now
      @iterations.times { value = yield }
      [((now - started) / @iterations).round(6), value]
    end

    def now = @clock.call(Process::CLOCK_MONOTONIC)
  end
end
