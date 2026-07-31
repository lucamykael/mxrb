# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql do
  # rubocop:disable Metrics/MethodLength
  def project_with_query(dir, query: nil, source_type: 'DataSets$OqlDataSetSource')
    FileUtils.mkdir_p(dir)
    path = File.join(dir, 'oql.mpr')
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) do
        entity(:Product) do
          string :Name
          decimal :Price
        end
      end
    end
    return path unless query

    Mxrb.open(path, readonly: false) do |project|
      project.mpr.insert_unit(
        container_uuid: project.modules.first.id,
        containment_name: 'Documents',
        contents_doc: {
          '$Type' => 'DataSets$DataSet',
          'Name' => 'Products',
          'Source' => { '$Type' => source_type, 'Query' => query }
        }
      )
    end
    path
  end
  # rubocop:enable Metrics/MethodLength

  def query(source, parameters: [])
    Mxrb::Oql::Query.new(
      'id', 'Shop.Products', 'Products', :dataset, source, 'unit',
      %w[Source Query], 'DataSets$OqlDataSetSource', parameters.freeze
    )
  end

  it 'only exposes OQL APIs when native OQL exists' do
    Dir.mktmpdir do |dir|
      path = project_with_query(dir)
      Mxrb.open(path) do |project|
        expect(project).not_to be_oql
        expect(project.oql_queries).to be_empty
        expect(project.oql_sql_views).to be_empty
      end
    end
  end

  it 'discovers native dataset OQL with ownership, path, and bind parameters' do
    Dir.mktmpdir do |dir|
      path = project_with_query(
        dir,
        query: 'SELECT \'$Ignored\', p/Name FROM Shop.Product AS p ' \
               'WHERE p/Name = $Name OR p/Name = $Name -- $AlsoIgnored'
      )
      Mxrb.open(path) do |project|
        discovered = project.oql_queries.fetch(0)
        expect(project).to be_oql
        expect(discovered.to_h).to include(
          qualified_name: 'Shop.Products',
          name: 'Products',
          kind: :dataset,
          path: %w[Source Query],
          source_type: 'DataSets$OqlDataSetSource',
          parameters: ['Name']
        )
        expect(discovered.id).to eq(discovered.unit_id)
        expect(project.oql_queries).to equal(project.oql_queries)
      end
    end
  end

  it 'discovers OqlQuery fields owned by embedded view entities' do
    Dir.mktmpdir do |dir|
      path = project_with_query(dir)
      Mxrb.open(path, readonly: false) do |project|
        domain = project.modules.first.domain_model
        raw = project.raw_unit(domain.id)
        document = project.parse_bson(raw)
        entity = Mxrb::IO::BsonCodec.parse_array(document.fetch('entities'))[:items].first
        entity['$Type'] = 'DomainModels$ViewEntity'
        entity['OqlQuery'] = 'SELECT Name FROM Shop.Product'
        project.mpr.update_unit(domain.id, document)
        project.refresh!

        discovered = project.oql_queries.fetch(0)
        expect(discovered.kind).to eq(:view_entity)
        expect(discovered.path.last).to eq('OqlQuery')
        expect(discovered.id).not_to eq(discovered.unit_id)
      end
    end
  end

  it 'ignores Query fields whose native source type is not OQL' do
    Dir.mktmpdir do |dir|
      path = project_with_query(
        dir, query: 'SELECT Name FROM Shop.Product',
             source_type: 'DataSets$JavaActionDataSetSource'
      )
      expect(Mxrb.open(path, &:oql_queries)).to be_empty
    end
  end

  it 'discovers an orphan generic OQL source without inventing a module owner' do
    Dir.mktmpdir do |dir|
      path = project_with_query(dir)
      Mxrb.open(path, readonly: false) do |project|
        project.mpr.insert_unit(
          container_uuid: SecureRandom.uuid,
          containment_name: 'Documents',
          contents_doc: {
            '$Type' => 'Queries$OqlDocument',
            'Source' => {
              '$Type' => 'Queries$OqlSource',
              'Query' => 'SELECT Name FROM Shop.Product'
            }
          }
        )
        project.refresh!

        discovered = project.oql_queries.fetch(0)
        expect(discovered.kind).to eq(:oql)
        expect(discovered.qualified_name).to match(/\AOQL_[0-9a-f]{8}\z/)
      end
    end
  end

  it 'renders PostgreSQL logical tables, attributes, literals, comments, and binds safely' do
    source = <<~OQL
      -- $Ignored
      SELECT p/Name, p.Price, 'literal $Ignored' AS Text
      FROM Shop.Product AS p
      WHERE p/Name = $Name /* retained */
    OQL
    view = described_class::Translator.new.translate(query(source, parameters: ['Name']))

    expect(view).to be_supported
    expect(view.confidence).to eq(:logical)
    expect(view.dialect).to eq(:postgresql)
    expect(view.sql).to include(
      '"shop$product" AS p',
      'p."name"',
      'p."price"',
      "'literal $Ignored'",
      'p."name" = :Name',
      '-- $Ignored',
      '/* retained */'
    )
    expect(view.parameters).to eq(['Name'])
    expect(view.warnings.join).to match(/verify.*Runtime database schema/)
  end

  it 'reorders legacy FROM-first OQL and retains top-level tail clauses' do
    source = <<~OQL
      FROM Shop.Product AS p
      WHERE p/Price > $Minimum
      GROUP BY p/Name
      SELECT p/Name, SUM(p/Price) AS Total
      ORDER BY Total
    OQL
    view = described_class::Translator.new(dialect: :ansi)
                                      .translate(query(source, parameters: ['Minimum']))

    expect(view.sql).to start_with('SELECT')
    expect(view.sql.index('FROM')).to be > view.sql.index('SELECT')
    expect(view.sql.index('ORDER BY')).to be > view.sql.index('GROUP BY')
    expect(view.sql).to include(
      '"Shop.Product" AS p',
      'p."Name"',
      'p."Price" > :Minimum'
    )
  end

  it 'supports SQL Server quoting, quoted entity names, and implicit aliases' do
    source = %(SELECT Order/Name FROM Sales."Order" Order WHERE Order/Name = 'A')
    view = described_class::Translator.new(dialect: :sql_server).translate(query(source))

    expect(view.sql).to include(
      'FROM [sales$order] Order',
      'Order.[name]'
    )
  end

  it 'translates entity references inside subqueries and preserves doubled quotes' do
    source = <<~OQL
      SELECT temp.Name, 'it''s safe'
      FROM (SELECT p/Name AS Name FROM Shop.Product p) AS temp
    OQL
    view = described_class::Translator.new.translate(query(source))

    expect(view.sql).to include('"shop$product" p', "'it''s safe'")
  end

  it 'refuses writes, multiple statements, and association-path joins' do
    translator = described_class::Translator.new
    write = translator.translate(query("UPDATE Shop.Product SET Name = 'x'"))
    multiple = translator.translate(query('SELECT Name FROM Shop.Product; DELETE FROM Shop.Product'))
    association = translator.translate(
      query('SELECT p/Name FROM Shop.Product p JOIN p/Shop.Product_Category/Shop.Category c')
    )

    expect(write).not_to be_supported
    expect(write.confidence).to eq(:unsupported)
    expect(write.warnings.join).to match(/read-only/)
    expect(multiple.warnings.join).to match(/multiple/)
    expect(association.warnings.join).to match(/association-path/)
  end

  it 'handles incomplete inspection input without interpolating it' do
    translator = described_class::Translator.new
    empty = translator.translate(query(''))
    trailing_parameter = translator.translate(query('SELECT Name FROM Shop.Product $'))
    open_comment = translator.translate(query('SELECT Name FROM Shop.Product /* open'))
    from_only = translator.translate(query('FROM Shop.Product'))
    unqualified = translator.translate(query('SELECT Name FROM Product'))

    expect(empty).not_to be_supported
    expect(trailing_parameter.sql).to end_with('$')
    expect(open_comment.sql).to end_with('/* open')
    expect(from_only.sql).to include('"shop$product"')
    expect(unqualified.sql).to eq('SELECT Name FROM Product')
  end

  it 'rejects unknown dialects' do
    expect { described_class::Translator.new(dialect: :oracle) }
      .to raise_error(ArgumentError, /unsupported SQL dialect/)
  end

  it 'translates an ad-hoc OQL source with the same safe subset' do
    view = described_class::Translator.new.translate_source(
      'SELECT Product.Name FROM Shop.Product Product'
    )
    expect(view.query.qualified_name).to eq('AdHoc')
    expect(view.sql).to include('"shop$product"', '"name"')
  end

  it 'offers deterministic CLI text and JSON only for discovered OQL' do
    Dir.mktmpdir do |dir|
      empty = project_with_query(dir)
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'oql']
      stdout, stderr, status = Open3.capture3(*command, empty)
      expect(status).to be_success
      expect(stdout).to include('No native OQL found')
      expect(stderr).to be_empty

      populated = project_with_query(
        File.join(dir, 'nested'), query: 'SELECT Name FROM Shop.Product'
      )
      stdout, stderr, status = Open3.capture3(*command, populated, '--json', '--dialect', 'ansi')
      payload = JSON.parse(stdout)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(payload.dig(0, 'name')).to eq('Shop.Products')
      expect(payload.dig(0, 'dialect')).to eq('ansi')
    end
  end
end
# rubocop:enable Metrics/BlockLength
