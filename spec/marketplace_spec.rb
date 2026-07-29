# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Mxrb::Marketplace do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @package = File.join(dir, "package")
      FileUtils.mkdir_p(@package)
      File.write(
        File.join(@package, "mxrb-module.json"),
        JSON.generate(
          name: "orders", module_name: "Orders", version: "1.2.3",
          files: ["module.rb"]
        )
      )
      File.write(File.join(@package, "module.rb"), "self.module(:Orders)\n")
      @catalog_path = File.join(dir, "catalog.json")
      File.write(
        @catalog_path,
        JSON.generate(
          modules: [{
            name: "orders", version: "1.2.3", description: "Order tools",
            source: @package
          }]
        )
      )
      example.run
    end
  end

  it "searches local and built-in catalogs" do
    catalog = described_class::Catalog.new(@catalog_path)
    expect(catalog.entries.first.name).to eq("orders")
    expect(catalog.search("ORDER").map(&:name)).to eq(["orders"])
    expect(catalog.search.size).to eq(1)
    expect(catalog.find("orders").version).to eq("1.2.3")
    expect { catalog.find("missing") }
      .to raise_error(Mxrb::MarketplaceError, /not found/)

    expect(described_class::Catalog.new.search("shared").first.name)
      .to eq("shared-kernel")
  end

  it "installs local packages transactionally and writes a reproducible lock" do
    target = File.join(@dir, "project")
    installer = described_class::Installer.new(
      target: target, catalog: described_class::Catalog.new(@catalog_path)
    )
    installation = installer.install("orders")

    expect(File.read(File.join(installation.destination, "module.rb")))
      .to include("Orders")
    expect(installation.digest).to match(/\A[0-9a-f]{64}\z/)
    lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
    expect(lock.dig("modules", "Orders", "version")).to eq("1.2.3")
    expect(lock.dig("modules", "Orders", "sha256")).to eq(installation.digest)
    expect { installer.install("orders") }
      .to raise_error(Mxrb::MarketplaceError, /already exists/)
  end

  it "accepts a package directory without a catalog" do
    target = File.join(@dir, "direct")
    installation = described_class::Installer.new(target: target).install(@package)

    expect(installation.entry.version).to eq("local")
    expect(installation.module_name).to eq("Orders")
  end

  it "rejects malformed catalogs and unreadable sources" do
    File.write(@catalog_path, "{")
    expect { described_class::Catalog.new(@catalog_path).entries }
      .to raise_error(Mxrb::MarketplaceError, /invalid marketplace/)
    expect { described_class::Catalog.new(File.join(@dir, "none")).entries }
      .to raise_error(Mxrb::MarketplaceError, /cannot read/)
    expect { described_class::Catalog.new("http://example.test/catalog").entries }
      .to raise_error(Mxrb::MarketplaceError, /HTTPS/)
  end

  it "loads HTTPS catalogs and reports unsuccessful responses" do
    success = instance_double(Net::HTTPSuccess, body: File.read(@catalog_path))
    allow(success).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(Net::HTTP).to receive(:get_response).and_return(success)
    expect(described_class::Catalog.new("https://example.test/catalog").entries.size)
      .to eq(1)

    failure = double(code: "503")
    allow(failure).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    allow(Net::HTTP).to receive(:get_response).and_return(failure)
    expect { described_class::Catalog.new("https://example.test/catalog").entries }
      .to raise_error(Mxrb::MarketplaceError, /HTTP 503/)
  end

  it "rejects unsafe, empty, missing and malformed module packages" do
    target = File.join(@dir, "invalid")
    installer = described_class::Installer.new(target: target)
    manifest = File.join(@package, "mxrb-module.json")

    File.write(manifest, JSON.generate(module_name: "../Bad", files: ["module.rb"]))
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /invalid module name/)

    File.write(manifest, JSON.generate(module_name: "Bad", files: ["../secret"]))
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /unsafe module path/)

    File.write(manifest, JSON.generate(module_name: "Bad", files: ["missing.rb"]))
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /file is missing/)

    File.write(manifest, JSON.generate(module_name: "Bad", files: []))
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /no files/)

    File.write(manifest, "{")
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /invalid module manifest/)

    FileUtils.rm_f(manifest)
    expect { installer.install(@package) }
      .to raise_error(Mxrb::MarketplaceError, /manifest is missing/)
  end

  it "validates built-in slugs and Git fetch results" do
    installer = described_class::Installer.new(target: @dir)
    expect(installer.send(:builtin_path, "builtin:shared-kernel"))
      .to end_with("marketplace/modules/shared-kernel")
    expect { installer.send(:builtin_path, "builtin:../bad") }
      .to raise_error(Mxrb::MarketplaceError, /invalid built-in/)
    expect { installer.send(:builtin_path, "builtin:not-present") }
      .to raise_error(Mxrb::MarketplaceError, /unavailable/)

    entry = described_class::Entry.new(
      "remote", "1.0.0", "", "https://example.test/repo.git", "v1"
    )
    allow(Open3).to receive(:capture2e)
      .and_return(["clone failed", instance_double(Process::Status, success?: false)])
    expect do
      installer.send(:materialize, entry.source, entry, @dir)
    end.to raise_error(Mxrb::MarketplaceError, /clone failed/)

    allow(Open3).to receive(:capture2e)
      .and_return(["cloned", instance_double(Process::Status, success?: true)])
    expect(installer.send(:materialize, entry.source, entry, @dir))
      .to eq(File.join(@dir, "repository"))
  end
end
