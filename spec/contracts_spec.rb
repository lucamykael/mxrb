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

  it "writes, validates, and exports individual demo users" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'demo.mpr')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      exported = File.join(dir, 'exported')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) { module_role :User }
        security do
          user_role :User, module_roles: ['App.User']
          demo_user 'manager', entity: 'System.User', roles: ['User'], password: 'MxrbDemo123'
        end
      end

      mpr = Mxrb::IO::MprFile.open(source, readonly: true)
      security = mpr.all_units.map { mpr.parse_contents(_1) }
                    .find { _1['$Type'] == 'Security$ProjectSecurity' }
      users = Mxrb::IO::BsonCodec.parse_array(security['DemoUsers']).fetch(:items)
      expect(security['EnableDemoUsers']).to be true
      expect(users.fetch(0)).to include(
        '$Type' => 'Security$DemoUserImpl', 'UserName' => 'manager',
        'Entity' => 'System.User', 'Password' => 'MxrbDemo123'
      )
      expect(Mxrb::IO::BsonCodec.parse_array(users.fetch(0)['UserRoles']).fetch(:items))
        .to eq(['User'])
      mpr.close

      Mxrb::Exporter.new(source, exported).export!
      security_source = File.read(File.join(exported, 'app', 'security', 'security.rb'))
      expect(security_source).to include(
        'demo_user "manager"', 'entity: "System.User"', 'roles: ["User"]'
      )
      begin
        ENV['MXRB_OUTPUT_PATH'] = rebuilt
        load File.join(exported, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end
  end

  it "rejects invalid and duplicate demo-user references" do
    invalid_arguments = [
      ['', 'System.User', ['User'], 'secret', /name must not be empty/],
      ['bad name', 'System.User', ['User'], 'secret', /must not contain whitespace/],
      ['manager', 'SystemUser', ['User'], 'secret', /qualified as Module.Entity/],
      ['manager', 'System.User', [], 'secret', /at least one role/],
      ['manager', 'System.User', ['User'], '', /password must not be empty/]
    ]
    invalid_arguments.each do |name, entity, roles, password, message|
      expect do
        Mxrb::Dsl::SecurityBuilder.new.demo_user(name, entity:, roles:, password:)
      end.to raise_error(ArgumentError, message)
    end
    expect { Mxrb::Dsl::SecurityBuilder.new.evaluate_dir('/missing/demo-users') }
      .not_to raise_error

    expect do
      Mxrb::Dsl::Builder.new('/tmp/invalid-demo.mpr').tap do |builder|
        builder.module(:App) { entity :Account }
        builder.security do
          user_role :User
          demo_user 'manager', entity: 'App.Missing', roles: ['Manager'], password: 'secret'
        end
        builder.validate!
      end
    end.to raise_error(Mxrb::ValidationError, /missing user role.*Manager.*missing user entity/m)

    expect do
      Mxrb::Dsl::Builder.new('/tmp/duplicate-demo.mpr').tap do |builder|
        builder.module(:App)
        builder.security do
          user_role :User
          2.times { demo_user 'manager', entity: 'System.User', roles: ['User'], password: 'secret' }
        end
        builder.validate!
      end
    end.to raise_error(Mxrb::ValidationError, /duplicate demo user/)
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
          tokens: [], layouts: [], components: [], accessibility: [],
          themes: [], contrast_pairs: [], forbid_literal_colors: false
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
