# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "deterministic native payload fuzzing" do
  def canonical(value, field = nil)
    case value
    when Hash
      value.to_h { |key, child| [key, canonical(child, key)] }
    when Array
      value.map { canonical(_1) }
    when BSON::Binary
      return Mxrb::IO::BsonCodec.extract_id(value) if field == "$ID"

      [value.type, value.data]
    else
      value
    end
  end

  def fuzz_value(random, depth = 0)
    return [nil, true, false, random.rand(-100_000..100_000), "s#{random.rand(1_000_000)}"].sample(random:) if depth >= 3

    case random.rand(7)
    when 0 then nil
    when 1 then random.rand(-100_000..100_000)
    when 2 then random.rand * 10_000
    when 3 then "text-#{random.rand(1_000_000)}"
    when 4 then Array.new(random.rand(0..5)) { fuzz_value(random, depth + 1) }
    when 5
      Array.new(random.rand(0..5)).to_h do
        ["key#{random.rand(1_000_000)}", fuzz_value(random, depth + 1)]
      end
    else
      BSON::Binary.new(random.bytes(random.rand(0..32)))
    end
  end

  it "round-trips randomized nested BSON documents without type or value loss" do
    random = Random.new(0x4D_58_52_42)
    250.times do |index|
      document = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Fuzz$Document#{index % 9}",
        "Name" => "Case#{index}",
        "Payload" => fuzz_value(random)
      }
      bytes = Mxrb::IO::BsonCodec.serialize(document)
      expect(canonical(Mxrb::IO::BsonCodec.parse(bytes))).to eq(canonical(document))
      expect(Mxrb::IO::BsonCodec.contents_hash(bytes))
        .to match(%r{\A[A-Za-z0-9+/]{43}=\z})
    end
  end

  it "round-trips randomized mxunit payloads through atomic files" do
    random = Random.new(0x56_32)
    Dir.mktmpdir do |directory|
      50.times do |index|
        document = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Fuzz$External#{index % 5}",
          "Payload" => fuzz_value(random)
        }
        path = File.join(directory, "#{index}.mxunit")
        Mxrb::IO::MxunitCodec.write_atomic(path, Mxrb::IO::MxunitCodec.serialize(document))
        expect(canonical(Mxrb::IO::MxunitCodec.read(path))).to eq(canonical(document))
      end
      expect(Dir.glob(File.join(directory, "*.tmp-*"))).to be_empty
    end
  end
end
