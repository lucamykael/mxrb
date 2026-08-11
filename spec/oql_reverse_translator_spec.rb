# frozen_string_literal: true

require 'json'
require 'open3'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Oql::ReverseTranslator do
  def build_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Shop) do
        entity(:Product) do
          string :Name
          decimal :UnitPrice
        end
        entity(:Order) { string :Number }
      end
    end
  end

  it 'restores canonical entities, attributes, joins, clauses, and named parameters from PostgreSQL' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      build_project(path)
      sql = <<~SQL
        SELECT p."name", SUM(p."unitprice") AS "Total",
               p."unitprice" / 2 AS "Half", CHAR_LENGTH(p."name") AS "NameLength"
        FROM public."shop$product" AS p
        JOIN "shop$order" AS o ON COALESCE(o."number", p."name") = p."name"
        WHERE p."name" <> 'retired' AND p."unitprice" > :Minimum
        GROUP BY p."name"
        HAVING SUM(p."unitprice") > :Minimum
        ORDER BY "Total"
        LIMIT 10 OFFSET 2
      SQL

      projection = Mxrb.open(path) { _1.sql_to_oql(sql) }

      expect(projection).to be_supported
      expect(projection.confidence).to eq(:inferred)
      expect(projection.parameters).to eq(['Minimum'])
      expect(projection.warnings.join).to include('schema public')
      expect(projection.oql).to include(
        'FROM Shop.Product AS p',
        'JOIN Shop."Order" AS o',
        'p/Name',
        'p/UnitPrice',
        'o/Number',
        'p/UnitPrice : 2',
        'LENGTH(p/Name)',
        "p/Name != 'retired'",
        '$Minimum',
        'GROUP BY p/Name',
        'LIMIT 10 OFFSET 2'
      )
    end
  end

  it 'converts ANSI logical names, comma sources, wildcards, comments, and UNION' do
    sql = <<~SQL
      -- retained
      SELECT p.*, o."Number" AS OrderNumber
      FROM "Shop.Product" p, Shop."Order" o
      WHERE p."Name" = o."Number"
      UNION ALL
      SELECT p.*, o."Number" AS OrderNumber
      FROM Shop.Product p, Shop."Order" o
    SQL
    projection = described_class.new(dialect: :ansi).translate(sql)

    expect(projection).to be_supported
    expect(projection.confidence).to eq(:logical)
    expect(projection.oql).to include(
      '-- retained', 'p/*', 'o/Number', 'FROM Shop.Product p, Shop."Order" o',
      'WHERE p/Name = o/Number', 'UNION ALL'
    )
  end

  it 'converts SQL Server brackets and named parameters while inferring physical names' do
    sql = 'SELECT o.[number] FROM [shop$order] o WHERE o.[number] = @Number'
    projection = described_class.new(dialect: :sql_server).translate(sql)

    expect(projection).to be_supported
    expect(projection.confidence).to eq(:inferred)
    expect(projection.oql).to eq(
      'SELECT o/number FROM shop."order" o WHERE o/number = $Number'
    )
    expect(projection.parameters).to eq(['Number'])
    expect(projection.warnings.join).to match(/casing was inferred/)
    expect(Mxrb::Oql::Translator.tokens('SELECT [na]]me]').map(&:text))
      .to include('[na]]me]')
  end

  it 'round-trips the logical subset emitted by the OQL to SQL translator' do
    source = 'SELECT p/Name FROM Shop.Product p WHERE p/UnitPrice > $Minimum ORDER BY p/Name LIMIT 5'
    sql = Mxrb::Oql::Translator.new(dialect: :ansi).translate_source(source).sql
    projection = described_class.new(dialect: :ansi).translate(sql)

    expect(projection).to be_supported
    expect(projection.oql).to include(
      'SELECT p/Name', 'FROM Shop.Product p', 'p/UnitPrice > $Minimum',
      'ORDER BY p/Name LIMIT 5'
    )
  end

  it 'rejects writes, unsafe dialect constructs, positional binds, and unmappable tables' do
    translator = described_class.new
    cases = {
      "UPDATE shop$product SET name = 'x'" => /read-only/,
      'SELECT * FROM shop$product; SELECT * FROM shop$product' => /multiple/,
      'WITH p AS (SELECT * FROM shop$product) SELECT * FROM p' => /keyword WITH/,
      'SELECT created_at::date FROM shop$product' => /casts using ::/,
      "SELECT * FROM shop$product WHERE name ILIKE 'a%'" => /ILIKE/,
      'SELECT * FROM shop$product WHERE id = ?' => /positional/,
      'SELECT * FROM shop$product WHERE id = $1' => /positional/,
      'SELECT * FROM products' => /cannot be mapped/,
      'SELECT NOW() FROM shop$product' => /function NOW/,
      'SELECT TOP 10 * FROM shop$product' => /keyword TOP/,
      'SELECT DISTINCT ON (name) name FROM shop$product' => /DISTINCT ON/,
      'SELECT * FROM (SELECT * FROM shop$product) p' => /table subqueries/,
      "SELECT name || 'x' FROM shop$product" => /concatenation/
    }

    cases.each do |sql, warning|
      projection = translator.translate(sql)
      expect(projection).not_to be_supported
      expect(projection.confidence).to eq(:unsupported)
      expect(projection.warnings.join).to match(warning)
    end
  end

  it 'rejects unknown dialects and malformed named parameters' do
    expect { described_class.new(dialect: :oracle) }
      .to raise_error(ArgumentError, /unsupported SQL dialect/)

    projection = described_class.new.translate('SELECT * FROM shop$product WHERE name = :')
    expect(projection).not_to be_supported
    expect(projection.warnings.join).to match(/missing its name/)

    expect(described_class.new.translate('SELECT 1').warnings.join)
      .to match(/does not reference/)
    expect(described_class.new.translate('SELECT * FROM 42').warnings.join)
      .to match(/cannot be mapped/)
    expect(described_class.new.translate('SELECT * FROM public."invalid$"').warnings.join)
      .to match(/cannot be mapped/)

    named = described_class.new.translate(
      'SELECT * FROM shop$product WHERE name = $Name'
    )
    expect(named.parameters).to eq(['Name'])
  end

  it 'exposes deterministic CLI text, JSON, project mapping, stdin, and failure status' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      build_project(path)
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'query']
      sql = 'SELECT p."name" FROM "shop$product" p WHERE p."name" = :Name'

      stdout, stderr, status = Open3.capture3(
        *command, sql, '--from', 'sql', '--to', 'oql', '--project', path,
        '--json', '--dialect', 'postgresql'
      )
      payload = JSON.parse(stdout)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(payload).to include(
        'supported' => true, 'oql' => include('Shop.Product', 'p/Name', '$Name'),
        'parameters' => ['Name']
      )

      stdout, stderr, status = Open3.capture3(
        *command, '--input', '-', '--from', 'sql', '--dialect', 'ansi',
        stdin_data: 'SELECT Name FROM Shop.Product'
      )
      expect(status).to be_success
      expect(stdout).to include('SQL source:', 'OQL (ansi, logical):', 'FROM Shop.Product')
      expect(stderr).to be_empty

      stdout, _stderr, status = Open3.capture3(
        *command, 'SELECT * FROM products', '--from', 'sql', '--json'
      )
      expect(status).not_to be_success
      expect(JSON.parse(stdout)).to include('supported' => false, 'oql' => nil)

      stdout, stderr, status = Open3.capture3(
        *command, 'SELECT p/Name FROM Shop.Product p', '--from', 'oql',
        '--to', 'sql', '--dialect', 'ansi', '--json'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to include(
        'supported' => true, 'from' => 'oql', 'to' => 'sql',
        'sql' => include('p."Name"', '"Shop.Product"')
      )
    end
  end
end
# rubocop:enable Metrics/BlockLength
