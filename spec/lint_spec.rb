# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "built-in semantic quality rules" do
  def analyze_definition
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lint.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Shop) do
          module_role :User
          entity :Product
          entity(:Session) { non_persistent! }
          entity(:Secured) do
            access_rule "Shop.User", read: :all
          end
          page :Home
          microflow(:PublicFlow, public: true) { allowed_roles }
          microflow(:Excluded) { excluded }
          nanoflow(:Documented, public: true) do
            documentation "Public client contract"
            allowed_roles :User
          end
          repository :Catalog, public: true
          repository :DocumentedCatalog, public: true, documentation: "Catalog port"
          menu :Main
        end
        security do
          security_level :CheckEverything
          user_role :User, module_roles: %w[Shop.User Shop.User]
          user_role :Auditor, module_roles: ["Shop.User"]
        end
        navigation do
          profile :Responsive, home_page: "Shop.Missing",
                   sign_in_page: "Shop.Home", menu: "Shop.Main",
                   role_homes: { User: "Shop.AlsoMissing" }
        end
      end
      yield path
    end
  end

  it "reports security, public-contract, navigation and role quality issues" do
    analyze_definition do |path|
      report = Mxrb.open(path, &:analyze)
      rules = report.diagnostics.map(&:rule)

      expect(rules).to include(
        :persistent_entity_without_access,
        :secured_artifact_without_roles,
        :public_contract_without_documentation,
        :missing_navigation_target,
        :duplicate_module_role
      )
      expect(report.diagnostics.count { _1.rule == :missing_navigation_target }).to eq(2)
      expect(report.diagnostics.count { _1.rule == :public_contract_without_documentation }).to eq(2)
      expect(report.valid?).to be false
    end
  end

  it "returns the same built-in diagnostics from a warmed semantic cache" do
    analyze_definition do |path|
      first = Mxrb.open(path, readonly: false, &:analyze)
      second = Mxrb.open(path, readonly: false, &:analyze)

      expect(second.diagnostics.map { [_1.rule, _1.message] })
        .to eq(first.diagnostics.map { [_1.rule, _1.message] })
    end
  end

  it "does not apply strict-security rules when project security is not strict" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "permissive.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:App) do
          entity :Record
          page :Home
        end
      end

      rules = Mxrb.open(path, &:analyze).diagnostics.map(&:rule)
      expect(rules).not_to include(
        :persistent_entity_without_access,
        :secured_artifact_without_roles
      )
    end
  end

  it "ignores incomplete entity metadata defensively" do
    artifact = Mxrb::Semantic::Artifact.new(
      id: "entity:missing", qualified_name: "App.Missing", kind: :entity,
      module_name: "App", name: "Missing", unit_id: nil, path: [], metadata: {}
    )
    analyzer = Mxrb::Semantic::Analyzer.allocate
    analyzer.instance_variable_set(:@index, double(artifacts: [artifact]))

    diagnostics = analyzer.send(
      :persistent_access_diagnostics,
      { "SecurityLevel" => "CheckEverything" }
    )
    expect(diagnostics).to be_empty
  end
end
