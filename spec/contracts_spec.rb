# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "typed project contracts" do
  def define_contract_project(path)
    Mxrb.define(path) do
      mendix_version "10.18.0"

      self.module(:Shop) do
        module_role :User
        page(:Home) { title "Home" }
        page(:SignIn) { title "Sign in" }
        menu :Main do
          item "Home", page: "Shop.Home"
        end
      end

      security do
        security_level :CheckEverything
        user_role :Administrator, module_roles: ["Shop.User"], admin: true
        admin_user_role :Administrator
        demo_users false
        guest_access true, role: "Administrator"
        sign_in_microflow "Shop.SignIn"
        password_policy minimum_length: 12, require_digit: true,
                        require_mixed_case: false, require_symbol: true
      end

      navigation do
        profile :Responsive, home_page: "Shop.Home",
                 sign_in_page: "Shop.SignIn", menu: "Shop.Main",
                 role_homes: { Administrator: "Shop.Home" }
        profile :Offline, home_page: "Shop.Home", offline: true
      end

      design_system do
        color :primary, value: "#3366ff"
        spacing :medium, value: "1rem"
        radius :card
        typography :body, value: "Inter"
        breakpoint :desktop, value: "1200px"
        layout "Atlas_Core.Atlas_Default"
        component "Shop.ProductCard"
        accessibility "WCAG 2.2 AA"
      end
    end
  end

  it "persists enhanced security fields in the native project document" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "contracts.mpr")
      define_contract_project(path)

      Mxrb.open(path) do |project|
        raw = project.all_units.find do |unit|
          project.parse_bson(unit)["$Type"] == "Security$ProjectSecurity"
        end
        doc = project.parse_bson(raw)

        expect(doc).to include(
          "SecurityLevel" => "CheckEverything",
          "AdminUserRole" => "Administrator",
          "EnableDemoUsers" => false,
          "EnableGuestAccess" => true,
          "GuestUserRole" => "Administrator",
          "SignInMicroflow" => "Shop.SignIn"
        )
        expect(doc.fetch("PasswordPolicySettings")).to include(
          "MinimumLength" => 12,
          "RequireDigit" => true,
          "RequireMixedCase" => false,
          "RequireSymbol" => true
        )
      end
    end
  end

  it "round-trips navigation and design-system contracts through exported Ruby" do
    Dir.mktmpdir do |dir|
      source_dir = File.join(dir, "source")
      rebuilt_dir = File.join(dir, "rebuilt")
      FileUtils.mkdir_p([source_dir, rebuilt_dir])
      source = File.join(source_dir, "contracts.mpr")
      exported = File.join(dir, "exported")
      rebuilt = File.join(rebuilt_dir, "contracts.mpr")
      define_contract_project(source)

      Mxrb::Exporter.new(source, exported).export!
      expect(File.read(File.join(exported, "app", "navigation", "navigation.rb")))
        .to include("profile :Responsive", "role_homes:", "offline: true")
      expect(File.read(File.join(exported, "app", "design_system", "design_system.rb")))
        .to include("color :primary", "accessibility")

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end

      source_definition = Mxrb.open(source, &:architecture_definition)
      rebuilt_definition = Mxrb.open(rebuilt, &:architecture_definition)
      expect(rebuilt_definition[:navigation]).to eq(source_definition[:navigation])
      expect(rebuilt_definition[:design_system]).to eq(source_definition[:design_system])
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end
  end

  it "exports disabled guest access without inventing an empty role" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source.mpr")
      exported = File.join(dir, "exported")
      rebuilt = File.join(dir, "rebuilt.mpr")
      Mxrb.define(source) do
        mendix_version "10.18.0"
        self.module(:App)
        security { guest_access false }
      end

      Mxrb::Exporter.new(source, exported).export!
      security_source = File.read(File.join(exported, "app", "security", "security.rb"))
      expect(security_source).to include("guest_access false")
      expect(security_source).not_to include("role: \"\"")

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.open(rebuilt, &:architecture_definition).dig(:security, :guest_user_role)).to be_nil
    end
  end

  it "supports empty optional contracts and optional native security fields" do
    Dir.mktmpdir do |dir|
      builder = Mxrb::Dsl::Builder.new(File.join(dir, "empty.mpr"))
      builder.navigation
      builder.design_system
      builder.security { sign_in_microflow nil }
      expect(builder.definition).to include(
        navigation: { profiles: [] },
        design_system: {
          tokens: [], layouts: [], components: [], accessibility: []
        }
      )
      expect(builder.definition.dig(:security, :sign_in_microflow)).to be_nil

      exporter = Mxrb::Exporter.new("unused.mpr", dir)
      security = exporter.send(
        :security_source,
        {
          "SecurityLevel" => "CheckNothing",
          "UserRoles" => Mxrb::IO::BsonCodec.build_array([]),
          "AdminUserRole" => "",
          "EnableDemoUsers" => false,
          "EnableGuestAccess" => false,
          "GuestUserRole" => "",
          "SignInMicroflow" => "",
          "PasswordPolicySettings" => nil
        }
      )
      repositories = exporter.send(
        :repositories_source,
        [{ name: "Catalog", documentation: "Port", public: false, implementation: nil }]
      )
      expect(security).not_to include("password_policy")
      expect(repositories).to include('documentation: "Port"')
    end
  end

  it "preserves unknown password-policy properties as typed extension keys" do
    exporter = Mxrb::Exporter.new("unused.mpr", Dir.mktmpdir)
    source = exporter.send(
      :security_source,
      {
        "SecurityLevel" => "CheckEverything",
        "UserRoles" => Mxrb::IO::BsonCodec.build_array([]),
        "AdminUserRole" => "",
        "EnableDemoUsers" => false,
        "EnableGuestAccess" => false,
        "GuestUserRole" => "",
        "SignInMicroflow" => "",
        "PasswordPolicySettings" => {
          "$ID" => "opaque", "$Type" => "Security$PasswordPolicySettings",
          "MinimumLength" => 14, "MaximumPasswordAge" => 90
        }
      }
    )
    builder = Mxrb::Dsl::Builder.new("/tmp/unused.mpr")
    builder.instance_eval(source)
    expect(builder.definition.dig(:security, :password_policy)).to include(
      minimum_length: 14,
      MaximumPasswordAge: 90
    )
  end
end
