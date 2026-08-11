# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Flymetothemoon Ruby-to-Mendix certification' do
  let(:fixture) { File.expand_path('fixtures/flymetothemoon/project.rb', __dir__) }
  let(:cli) { File.expand_path('../bin/mxrb', __dir__) }

  def generate_source(path)
    stdout, stderr, status = Open3.capture3(
      { 'MXRB_OUTPUT_PATH' => path }, RbConfig.ruby, fixture
    )
    raise "fixture failed: #{stdout}\n#{stderr}" unless status.success?
  end

  def export_fly(source, destination)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, cli, 'export', source, destination,
      '--mode', 'ruby', '--flymetothemoon'
    )
    expect(status).to be_success, stderr
    expect(stdout).to include('Exported ruby project with flymetothemoon')
  end

  def manifest(root)
    JSON.parse(File.read(File.join(root, '.mxrb', 'ruby-app.json')))
  end

  def customize_ruby(root)
    model = File.join(root, 'app', 'models', 'certification', 'order.rb')
    source = File.read(model)
    File.write(
      model,
      source.sub(
        "  end\nend\n",
        "    attribute :audit_note, type: :string, mendix_name: 'AuditNote', required: false\n" \
        "  end\nend\n"
      )
    )

    service = Dir[File.join(root, 'app', 'services', 'certification', '*.rb')]
              .find { File.read(_1).include?('Certification.ChoosePriority') }
    source = File.read(service)
    File.write(
      service,
      source.sub('native_call(arguments)', "arguments.fetch(:Urgent, false) ? 'ruby-high' : 'ruby-normal'")
    )
  end

  def assert_business_contract(path)
    Mxrb.open(path) do |project|
      expect(project.mendix_version).to eq('11.12.1')
      mod = project.modules.find { _1.name == 'Certification' }
      expect(mod.entities.map(&:name)).to contain_exactly('Customer', 'Product', 'Order', 'OrderLine')
      enumeration = mod.enumerations.find { _1['Name'] == 'OrderStatus' }
      values = Mxrb::IO::BsonCodec.parse_array(enumeration.fetch('Values')).fetch(:items)
      expect(values.map { _1.fetch('Name') }).to eq(%w[New Processing Done])
      expect(project.modules.first.associations.map(&:name)).to contain_exactly(
        'Order_Customer', 'OrderLine_Order', 'OrderLine_Product'
      )
      expect(mod.microflows.map(&:name)).to include(
        'SeedOrder', 'CountOrders', 'ChoosePriority', 'DeleteOrders'
      )
      expect(mod.pages.map(&:name)).to include('Dashboard')
      expect(mod.scheduled_events.map { _1.fetch('Name') }).to include('DailyOrderAudit')
    end
  end

  it 'codes a business app in Ruby, runs it, and preserves it through repeated MPR round-trips' do
    Dir.mktmpdir('mxrb-fly-certification-') do |dir|
      source = File.join(dir, 'Certification.mpr')
      app = File.join(dir, 'fly_app')
      unchanged = File.join(dir, 'unchanged.mpr')
      evolved = File.join(dir, 'evolved.mpr')
      second = File.join(dir, 'second-roundtrip.mpr')
      restored = File.join(dir, 'restored')

      generate_source(source)
      expect(Mxrb.validate(source)).to be_valid
      assert_business_contract(source)
      export_fly(source, app)

      expect(manifest(app).fetch('ruby_stack')).to include(
        'preset' => 'flymetothemoon', 'web_framework' => 'sinatra',
        'server' => 'puma', 'orm' => 'active_record'
      )
      stack_files = Dir[File.join(app, '{app,bin,config,spec}', '**', '*')].select { File.file?(_1) }
      expect(stack_files.grep(/\.(?:java|jar|class)\z/i)).to be_empty

      application = Mxrb::RubyApp::Application.new(app)
      expect(application.invoke_service('Certification.SeedOrder').fetch(:result))
        .to include(type: 'Certification.Order')
      expect(application.invoke_service('Certification.CountOrders').fetch(:result)).to eq(1)
      expect(application.invoke_service('Certification.ChoosePriority', Urgent: true).fetch(:result)).to eq('high')
      customer = application.create_record('Certification.Customer', 'Name' => 'Ada', 'Active' => true)
      expect(application.record('Certification.Customer', customer.fetch(:id))).to include(id: customer.fetch(:id))
      changes = { 'Email' => 'ada@example.test' }
      expect(application.update_record('Certification.Customer', customer.fetch(:id), changes))
        .to include(attributes: include('Email' => 'ada@example.test'))
      expect(application.delete_record('Certification.Customer', customer.fetch(:id))).to be(true)
      expect(application.page('Certification.Dashboard')).to include(title: 'Dashboard')
      application.close

      expect(Mxrb::RubyApp.compile(app, unchanged)).to eq(unchanged)
      expect(Mxrb.validate(unchanged)).to be_valid
      expect(Mxrb.compare(source, unchanged)).to be_identical

      customize_ruby(app)
      customized = Mxrb::RubyApp::Application.new(app)
      expect(customized.invoke_service('Certification.ChoosePriority', Urgent: true).fetch(:result))
        .to eq('ruby-high')
      customized.close

      expect(Mxrb::RubyApp.compile(app, evolved)).to eq(evolved)
      expect(Mxrb.validate(evolved)).to be_valid
      assert_business_contract(evolved)
      audit_note = Mxrb.open(evolved) do |project|
        certification = project.modules.find { _1.name == 'Certification' }
        order = certification.entities.find { _1.name == 'Order' }
        order.attributes.find do |attribute|
          attribute.name == 'AuditNote'
        end
      end
      expect(audit_note).not_to be_nil

      Mxrb::Exporter.new(evolved, restored, mode: :ruby).export!
      expect(manifest(restored).dig('ruby_stack', 'preset')).to eq('flymetothemoon')
      restored_service = Dir[File.join(restored, 'app', 'services', 'certification', '*.rb')]
                         .find { File.read(_1).include?('Certification.ChoosePriority') }
      expect(File.read(restored_service)).to include("'ruby-high'", "'ruby-normal'")
      expect(Mxrb::RubyApp.compile(restored, second)).to eq(second)
      expect(Mxrb.validate(second)).to be_valid
      expect(Mxrb.compare(evolved, second)).to be_identical
    ensure
      application&.close
      customized&.close
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
