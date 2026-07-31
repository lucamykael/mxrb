# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'rbconfig'

RSpec.describe 'semantic search (sqlite-vec + TF-IDF)' do
  def make_mpr(path)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Sales) do
        entity :Order
        microflow :CreateOrder
      end
    end
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @mpr_path = File.join(dir, 'search_test.mpr')
      make_mpr(@mpr_path)
      ex.run
    end
  end

  # ── TF-IDF embedder ───────────────────────────────────────────────────────

  describe Mxrb::Semantic::TfidfEmbedder do
    subject(:embedder) { described_class.new }

    it 'produces a vector of the expected dimension' do
      vec = embedder.embed('Sales.Order entity')
      expect(vec.size).to eq(Mxrb::Semantic::TfidfEmbedder::DIM)
    end

    it 'returns a unit-normalized vector' do
      vec = embedder.embed('CreateOrder microflow')
      norm = Math.sqrt(vec.sum { _1**2 })
      expect(norm).to be_within(1e-9).of(1.0)
    end

    it 'returns a zero vector for empty input' do
      vec = embedder.embed('')
      expect(vec).to eq(Array.new(Mxrb::Semantic::TfidfEmbedder::DIM, 0.0))
      expect(embedder.embed('a 1')).to eq(vec)
      expect(embedder.send(:normalize, [0.0, 0.0])).to eq([0.0, 0.0])
    end

    it 'is deterministic across calls' do
      text = 'order payment microflow'
      expect(embedder.embed(text)).to eq(embedder.embed(text))
    end

    it 'produces different vectors for different inputs' do
      expect(embedder.embed('order')).not_to eq(embedder.embed('microflow'))
    end
  end

  # ── Embedder factory ──────────────────────────────────────────────────────

  describe Mxrb::Semantic::Embedder do
    it 'returns a TfidfEmbedder when backend: :tfidf' do
      expect(described_class.build(backend: :tfidf)).to be_a(Mxrb::Semantic::TfidfEmbedder)
    end

    it 'raises on unknown backend' do
      expect { described_class.build(backend: :bogus) }
        .to raise_error(ArgumentError, /unknown embedding backend/)
    end

    it ':auto resolves to TfidfEmbedder when informers is absent' do
      allow(Mxrb::Semantic::OnnxEmbedder).to receive(:available?).and_return(false)
      expect(described_class.build(backend: :auto)).to be_a(Mxrb::Semantic::TfidfEmbedder)
    end

    it 'builds ONNX explicitly and through auto when available' do
      pipeline = ->(_text) { [[0.5, 0.5]] }
      allow(Mxrb::Semantic::OnnxEmbedder).to receive(:new)
        .and_return(Mxrb::Semantic::OnnxEmbedder.new(pipeline:))
      allow(Mxrb::Semantic::OnnxEmbedder).to receive(:available?).and_return(true)

      expect(described_class.build(backend: :onnx).backend).to eq(:onnx)
      expect(described_class.build(backend: :auto).backend).to eq(:onnx)
    end

    it 'ranks artifacts deterministically and validates vector dimensions' do
      artifact = Mxrb::Semantic::Artifact.new(
        '1', 'Sales.Order', :entity, 'Sales', 'Order', nil, nil,
        { documentation: 'Customer purchase' }.freeze
      )
      other = artifact.with(id: '2', qualified_name: 'Sales.Customer', name: 'Customer')
      embedder = Mxrb::Semantic::TfidfEmbedder.new

      expect(described_class.artifact_text(artifact)).to include(
        'Sales.Order', 'entity', 'Customer purchase'
      )
      expect(described_class.artifact_text(artifact.with(metadata: nil))).to include('Sales.Order')
      expect(described_class.rank([other, artifact], 'order', embedder:, limit: 1)).to eq([artifact])
      expect { described_class.dot([1.0], [1.0, 2.0]) }
        .to raise_error(ArgumentError, /dimensions/)
    end
  end

  describe Mxrb::Semantic::OnnxEmbedder do
    it 'uses an injected normalized pipeline and memoizes its dimension' do
      pipeline = instance_double(Proc)
      allow(pipeline).to receive(:call).and_return([0.2, 0.8])
      embedder = described_class.new(pipeline:)

      expect(embedder.backend).to eq(:onnx)
      expect(embedder.embed('order')).to eq([0.2, 0.8])
      expect(embedder.dimension).to eq(2)
      expect(embedder.dimension).to eq(2)
      allow(pipeline).to receive(:call).and_return([[0.3, 0.7]])
      expect(embedder.embed('nested')).to eq([0.3, 0.7])
    end

    it 'reports whether informers can be loaded' do
      allow(described_class).to receive(:require).with('informers').and_return(true)
      expect(described_class.available?).to be(true)
      allow(described_class).to receive(:require).with('informers').and_raise(LoadError)
      expect(described_class.available?).to be(false)
    end

    it 'builds the default normalized informers pipeline' do
      pipeline = ->(_text) { [0.1, 0.9] }
      stub_const('Informers', class_double('Informers', pipeline:))
      embedder = described_class.allocate
      allow(embedder).to receive(:require).with('informers').and_return(true)

      embedder.send(:initialize)
      expect(embedder.embed('order')).to eq([0.1, 0.9])
    end

    if ENV['MXRB_ONNX'] == '1'
      it 'runs the real local ONNX embedding backend' do
        expect(described_class).to be_available
        vector = described_class.new.embed('Create a customer order')

        expect(vector.size).to eq(384)
        expect(vector).to all(be_a(Float))
      end
    end
  end

  # ── VecStore + Index#semantic_search ─────────────────────────────────────

  describe Mxrb::Semantic::VecStore do
    let(:mpr) { instance_double(Mxrb::IO::MprFile) }
    let(:embedder) { Mxrb::Semantic::TfidfEmbedder.new }
    let(:fingerprint) { 'model-fingerprint' }

    before do
      allow(mpr).to receive(:load_vec_extension!).and_return(true)
      allow(mpr).to receive(:ensure_vec_table!)
      allow(mpr).to receive(:ensure_vec_meta_table!)
    end

    it 'records metadata only after rebuilding all artifacts' do
      artifact = Mxrb::Semantic::Artifact.new(
        'entity-1', 'Sales.Order', :entity, 'Sales', 'Order', nil, nil, {}.freeze
      )
      store = described_class.new(mpr, embedder:, fingerprint:)
      allow(mpr).to receive(:vec_meta).and_return(nil)
      allow(mpr).to receive(:vec_drop_index!)
      allow(mpr).to receive(:vec_transaction).and_yield
      allow(mpr).to receive(:vec_upsert)
      allow(mpr).to receive(:write_vec_meta!)

      expect(store).not_to be_compatible
      expect(store.rebuild!([artifact])).to equal(store)
      expect(mpr).to have_received(:vec_upsert).with(
        described_class::VEC_TABLE, 'entity-1', kind_of(String)
      )
      expect(mpr).to have_received(:write_vec_meta!).with(
        described_class::META_TABLE, 'tfidf', embedder.dimension, fingerprint
      )
    end

    it 'checks the complete cache identity and delegates KNN search' do
      metadata = { backend: 'tfidf', dimension: embedder.dimension, fingerprint: }
      allow(mpr).to receive(:vec_meta).and_return(metadata)
      allow(mpr).to receive(:vec_knn).and_return([{ id: '1', distance: 0.1 }])
      store = described_class.new(mpr, embedder:, fingerprint:)

      expect(store).to be_compatible
      expect(store.search('order', limit: 3)).to eq([{ id: '1', distance: 0.1 }])
    end

    it 'reports unavailable sqlite-vec without making it mandatory' do
      allow(described_class).to receive(:require).with('sqlite_vec').and_return(true)
      expect(described_class.available?).to be(true)
      allow(described_class).to receive(:require).with('sqlite_vec').and_raise(LoadError)
      expect(described_class.available?).to be(false)
    end
  end

  describe 'Index#semantic_search' do
    it 'returns ranked artifacts without sqlite-vec, including through Project' do
      allow(Mxrb::Semantic::VecStore).to receive(:available?).and_return(false)
      Mxrb.open(@mpr_path) do |project|
        results = project.semantic_search_artifacts('CreateOrder microflow', backend: :tfidf, limit: 1)
        expect(results.map(&:qualified_name)).to eq(['Sales.CreateOrder'])
        hits = project.semantic_search_hits('CreateOrder microflow', backend: :tfidf, limit: 1)
        expect(hits.first.artifact.qualified_name).to eq('Sales.CreateOrder')
        expect(hits.first.distance).to be_between(0.0, 1.0)
        expect { project.semantic_search_artifacts('order', limit: 0) }
          .to raise_error(ArgumentError, /limit must be positive/)
      end
    end

    it 'populates the vector index on first call and does not rebuild on the second' do
      store = instance_double(Mxrb::Semantic::VecStore, backend: :tfidf)
      allow(store).to receive(:compatible?).and_return(false, true)
      allow(store).to receive(:rebuild!).and_return(store)

      Mxrb.open(@mpr_path, readonly: false) do |project|
        index = project.semantic_index
        hit = index.artifacts.find { _1.qualified_name == 'Sales.Order' }
        allow(store).to receive(:search).and_return([
                                                      { id: 'missing', distance: 1.0 },
                                                      { id: hit.id, distance: 0.0 }
                                                    ])
        allow(Mxrb::Semantic::VecStore).to receive(:available?).and_return(true)
        allow(Mxrb::Semantic::VecStore).to receive(:new).and_return(store)

        expect(index.semantic_search('order', backend: :tfidf)).to eq([hit])
        expect(index.semantic_search_hits('order', backend: :tfidf).first.distance).to eq(0.0)
        expect(index.semantic_search('microflow', backend: :tfidf)).to eq([hit])
        expect(store).to have_received(:rebuild!).once
        expect(Mxrb::Semantic::VecStore).to have_received(:new).once
      end
    end

    it 'falls back to Ruby ranking if sqlite initialization or querying fails' do
      allow(Mxrb::Semantic::VecStore).to receive(:available?).and_return(true)
      allow(Mxrb::Semantic::VecStore).to receive(:new).and_raise(SQLite3::SQLException)

      Mxrb.open(@mpr_path, readonly: false) do |project|
        expect(project.semantic_search_artifacts('order', backend: :tfidf)).not_to be_empty
      end

      failing = instance_double(Mxrb::Semantic::VecStore, backend: :tfidf, compatible?: true)
      allow(failing).to receive(:search).and_raise(SQLite3::SQLException)
      allow(Mxrb::Semantic::VecStore).to receive(:new).and_return(failing)
      Mxrb.open(@mpr_path, readonly: false) do |project|
        expect(project.semantic_search_artifacts('order', backend: :tfidf)).not_to be_empty
      end
    end

    if ENV['MXRB_SQLITE_VEC'] == '1'
      it 'runs the real sqlite-vec index and reuses its fingerprinted metadata' do
        Mxrb.open(@mpr_path, readonly: false) do |project|
          first = project.semantic_search_artifacts('CreateOrder', backend: :tfidf)
          second = project.semantic_search_artifacts('Order', backend: :tfidf)
          metadata = project.mpr.vec_meta(Mxrb::Semantic::VecStore::META_TABLE)

          expect(first.map(&:qualified_name)).to include('Sales.CreateOrder')
          expect(second.map(&:qualified_name)).to include('Sales.Order')
          expect(metadata).to include(
            backend: 'tfidf',
            dimension: Mxrb::Semantic::TfidfEmbedder::DIM,
            fingerprint: kind_of(String)
          )
        end
      end
    end

    it 'exposes semantic ranking through the thin find CLI adapter' do
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'find', @mpr_path]
      stdout, stderr, status = Open3.capture3(*command, 'create order', '--semantic')

      expect(status).to be_success
      expect(stderr).to be_empty unless ENV['MXRB_ONNX'] == '1'
      expect(stdout).to include("Sales.CreateOrder\tmicroflow")
    end

    it 'offers a dedicated scored search CLI with backend, limit, and JSON output' do
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'search']
      stdout, stderr, status = Open3.capture3(
        *command, 'create order', @mpr_path, '--backend', 'tfidf', '--limit', '1'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include("rank\tdistance\tqualified_name\tkind")
      expect(stdout.lines.size).to eq(2)

      stdout, stderr, status = Open3.capture3(
        *command, 'create order', @mpr_path, '--backend', 'tfidf', '--limit', '1', '--json'
      )
      payload = JSON.parse(stdout)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(payload.first).to include('rank' => 1)
      expect(payload.first.fetch('qualified_name')).to start_with('Sales.')
      expect(payload.first.fetch('kind')).to be_a(String)
      expect(payload.first.fetch('distance')).to be_a(Float)
    end
  end
end
