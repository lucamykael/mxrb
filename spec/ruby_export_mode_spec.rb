# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby application export mode' do
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def define_source(path, runtime_metadata: false)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Sales) do
        enumeration(:OrderStatus) do
          value :New, caption: 'New order'
          value :Done, caption: 'Completed'
        end
        entity(:Customer) { string :Name }
        entity(:Order) do
          string :Number
          string :Notes
          boolean :Paid
          datetime :DueOn
          enum :Status, enumeration: 'Sales.OrderStatus'
          association :Customer
        end
        entity(:OrderInput) do
          non_persistent!
          string :Query
        end
        microflow(:Ping)
        microflow :AdapterCall do
          return_type :String
          call_app_service 'External.Echo', as: :result
          return_value '$result'
        end
        if runtime_metadata
          microflow(:Cleanup)
          scheduled_event :Cleanup, microflow: 'Sales.Cleanup', interval: 5, unit: :minutes
        end
        nanoflow(:ClientPing) { return_value 'true' }
        page :Dashboard do
          text :Heading, caption: 'Orders'
          text_box :Number, attribute: 'Sales.Order/Number', caption: 'Number' do
            on_change microflow: 'Sales.Ping'
          end
          text_area :Notes, attribute: 'Sales.Order/Notes', caption: 'Notes'
          check_box :Paid, attribute: 'Sales.Order/Paid', caption: 'Paid'
          date_picker :DueOn, attribute: 'Sales.Order/DueOn', caption: 'Due'
          drop_down :Status, attribute: 'Sales.Order/Status', caption: 'Status'
          reference_selector :Customer, attribute: 'Sales.Order_Customer', caption: 'Customer',
                                        display_attribute: 'Sales.Customer.Name'
          data_grid :Orders, entity: 'Sales.Order' do
            column :Number, attribute: 'Sales.Order/Number', caption: 'Number'
            column :Status, attribute: 'Sales.Order/Status', caption: 'Status'
            toolbar do
              new_button
              delete_button
            end
            on_change nanoflow: 'Sales.ClientPing'
          end
        end
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  it 'exports a conventional Ruby backend and React Vite frontend' do
    Dir.mktmpdir('mxrb-ruby-mode-') do |dir|
      source = File.join(dir, 'Sales.mpr')
      root = File.join(dir, 'sales_app')
      define_source(source, runtime_metadata: true)

      expect(Mxrb::Exporter.new(source, root, mode: :ruby).export!).to eq(root)
      manifest = JSON.parse(File.read(File.join(root, '.mxrb', 'ruby-app.json')))

      expect(manifest).to include('mode' => 'ruby')
      expect(manifest.fetch('frontend')).to include(
        'framework' => 'react', 'bundler' => 'vite'
      )
      expect(File).to exist(File.join(root, 'app', 'models', 'sales', 'order.rb'))
      expect(File).to exist(File.join(root, 'app', 'dtos', 'sales', 'order_input_dto.rb'))
      expect(File).not_to exist(File.join(root, 'app', 'dtos', 'sales', 'order_input_2.rb'))
      expect(File.read(File.join(root, 'frontend', 'package.json'))).to include(
        'react', 'vite'
      )
      frontend_source = File.read(File.join(root, 'frontend', 'src', 'App.jsx'))
      expect(frontend_source).to include(
        "api('/api/schema', {}, activeToken)", 'useState', 'executeNanoflow',
        'resolvedParameters[plan.parameters[0]] = activeContext', 'nanoflowValue',
        'function BoundField', "method: 'PATCH'", 'function DataGrid',
        'mxrb-grid-pagination', "api('/api/login'", 'localStorage.setItem(TOKEN_KEY',
        'headers.Authorization = `Bearer ${token}`', "api('/api/session'", "api('/api/logout'",
        'payload.records || []', 'records.slice(', "method: 'POST'", "method: 'DELETE'", '>Reload</button>'
      )
      expect(frontend_source).to include('module.enumerations || []', 'enumeration?.values || []')
      expect(frontend_source).not_to match(/localStorage[^\n]*(?:password|username)/i)
      adapter_source = File.read(File.join(root, 'config', 'adapters.rb'))
      expect(adapter_source).to include(
        'Registry.register_adapter(:app_service)',
        "Registry.register_java_custom_action('MyModule.MyAction')",
        ':import_mapping', ':document'
      )
      expect(adapter_source).not_to include('password=', 'token=')
      expect(File.read(File.join(root, 'config', 'environments', 'production.env.example')))
        .to include(
          'MXRB_SHARED_STORE_PATH=.mxrb/runtime/production-shared.sqlite3',
          'MXRB_SCHEDULER_LEASE_TTL=300', 'MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=false'
        )
      sales = manifest.fetch('modules').find { _1.fetch('name') == 'Sales' }
      expect(sales.fetch('services').map { _1.fetch('name') }).to include('Sales.Ping')
      expect(sales.fetch('services').first).to have_key('allowed_module_roles')
      expect(sales.fetch('associations')).to include(
        include('name' => 'Sales.Order_Customer', 'type' => 'Reference')
      )
      expect(sales.fetch('enumerations')).to include(
        include(
          'name' => 'Sales.OrderStatus',
          'values' => include(include('name' => 'New', 'caption' => 'New order'))
        )
      )
      order = sales.fetch('models').find { _1.fetch('name') == 'Sales.Order' }
      expect(order.fetch('attributes')).to include(
        include('name' => 'Status', 'type' => 'enum', 'enumeration' => 'Sales.OrderStatus')
      )
      expect(sales.fetch('scheduled_events')).to include(
        include('Name' => 'Cleanup', 'Microflow' => 'Sales.Cleanup')
      )
      expect(order).to include(
        'system_members', 'access_rules', 'lifecycle'
      )
      expect(sales.fetch('nanoflows')).to include(
        include('name' => 'Sales.ClientPing', 'runtime' => 'frontend')
      )
      expect(File).to exist(File.join(root, 'frontend', 'src', 'nanoflows', 'sales', 'client_ping.js'))
      expect(File).not_to exist(File.join(root, 'app', 'services', 'sales', 'client_ping.rb'))

      application = Mxrb::RubyApp::Application.new(root)
      expect(application.schema[:project]).to include('name' => 'Sales')
      expect(application.create_record('Sales.Order', 'Number' => 'SO-1')).to include(
        type: 'Sales.Order', attributes: include('Number' => 'SO-1')
      )
      expect(application.records('Sales.Order').size).to eq(1)
      serialized = application.records('Sales.Order').first
      expect(application.send(:deserialize, JSON.parse(JSON.generate(serialized))).id)
        .to eq(serialized.fetch(:id))
      changed_context = JSON.parse(JSON.generate(serialized))
      changed_context.fetch('attributes')['Number'] = 'SO-2'
      application.invoke_service('Sales.Ping', '__mxrb_context' => changed_context)
      expect(application.records('Sales.Order').first.dig(:attributes, 'Number')).to eq('SO-2')
      parent = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Sales.Order', id: 'parent', members: {})
      child = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Sales.Order', id: 'child', members: {})
      parent.members['Child'] = child
      child.members['Parent'] = parent
      expect(application.send(:serialize, parent).dig(:attributes, 'Child', :attributes, 'Parent'))
        .to eq(id: 'parent', type: 'Sales.Order')
      expect(application.call_service('Sales.Ping')).to be_nil
      expect { application.call_service('Sales.AdapterCall') }
        .to raise_error(Mxrb::NativeRuntimeError, /app_service adapter is not configured/)
      dashboard = application.page('Sales.Dashboard')
      expect(dashboard).to include(title: 'Dashboard')
      expect(dashboard.fetch(:widgets).map { _1.fetch('type') }).to include(
        'text_box', 'text_area', 'check_box', 'date_picker', 'drop_down', 'reference_selector', 'data_grid'
      )
      grid = dashboard.fetch(:widgets).find { _1.fetch('type') == 'data_grid' }
      expect(grid).to include(
        'options' => include('entity' => 'Sales.Order', 'columns' => include(include('name' => 'Number'))),
        'events' => include(include('kind' => 'nanoflow', 'handler' => 'ClientPing'))
      )
      number_input = dashboard.fetch(:widgets).find { _1.fetch('type') == 'text_box' }
      expect(number_input.fetch('events')).to include(
        include('kind' => 'microflow', 'handler' => 'Ping', 'event' => 'on_change')
      )
      customer_input = dashboard.fetch(:widgets).find { _1.fetch('type') == 'reference_selector' }
      expect(customer_input.fetch('options')).to include(
        'attribute' => 'Sales.Order_Customer', 'display_attribute' => 'Sales.Customer.Name'
      )
      application.close

      File.write(File.join(root, 'config', 'adapters.rb'), <<~RUBY)
        # frozen_string_literal: true

        Mxrb::RubyApp::Registry.register_adapter(:app_service) do |name, _document, _variables|
          "ruby-adapter:\#{name}"
        end
      RUBY
      adapted = Mxrb::RubyApp::Application.new(root)
      expect(adapted.call_service('Sales.AdapterCall')).to eq('ruby-adapter:External.Echo')
      adapted.close

      request_class = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end
      response_class = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end
      server = Mxrb::RubyApp::Server.new(root, port: 0)
      dispatch = lambda do |path, method = 'GET', body = ''|
        response_class.new(nil, nil, {}).tap do |response|
          server.send(:dispatch, request_class.new(path, method, body, {}, {}), response)
        end
      end
      created = dispatch.call('/api/entities/Sales.Order', 'POST', JSON.generate('Number' => 'SO-grid'))
      expect(created.status).to eq(201)
      record_id = JSON.parse(created.body).fetch('id')
      changed = dispatch.call(
        "/api/entities/Sales.Order/#{record_id}", 'PATCH', JSON.generate('Notes' => 'bound input')
      )
      expect(JSON.parse(changed.body).dig('attributes', 'Notes')).to eq('bound input')
      rows = dispatch.call('/api/entities/Sales.Order')
      expect(JSON.parse(rows.body).fetch('records')).to include(
        include('id' => record_id, 'attributes' => include('Number' => 'SO-grid'))
      )
      expect(dispatch.call("/api/entities/Sales.Order/#{record_id}", 'DELETE').status).to eq(200)
      server.application.close

      expect { Mxrb::RubyApp::Registry.register_adapter(:unsupported) {} }
        .to raise_error(ArgumentError, /unsupported Ruby adapter/)
      expect { Mxrb::RubyApp::Registry.register_adapter(:document) }
        .to raise_error(ArgumentError, /respond to call/)
      callback = ->(*) { 'document' }
      expect(Mxrb::RubyApp::Registry.register_adapter(:document, callback)).to equal(callback)
      expect(Mxrb::RubyApp::Registry.adapters).to include(document: callback)
    end
  end

  it 'round-trips Ruby model edits and transitions the Mendix version' do
    Dir.mktmpdir('mxrb-ruby-round-trip-') do |dir|
      source = File.join(dir, 'Sales.mpr')
      root = File.join(dir, 'sales_app')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_source(source)
      Mxrb::Exporter.new(source, root, mode: :ruby).export!

      model_path = File.join(root, 'app', 'models', 'sales', 'order.rb')
      frontend_path = File.join(root, 'frontend', 'src', 'App.jsx')
      model = File.read(model_path)
      File.write(
        model_path,
        model.sub(
          /^  end$/,
          "    attribute :total, type: :decimal, mendix_name: 'Total', " \
          "required: false, default: '0'\n  end"
        )
      )
      File.write(frontend_path, File.read(frontend_path).sub(
                                  'export default function App()',
                                  '// preserved through Mendix\nexport default function App()'
                                ))
      File.write(File.join(root, 'config', 'adapters.rb'), <<~RUBY)
        # frozen_string_literal: true
        Mxrb::RubyApp::Registry.register_adapter(:document) { |name, *, **| "document:\#{name}" }
      RUBY
      lifecycle = Mxrb::ProjectLifecycle.new(root)
      expect(lifecycle.upgrade('10.19.0', apply: true).from).to eq('10.18.0')

      expect(Mxrb::RubyApp.compile(root, rebuilt, mendix_version: '10.19.0')).to eq(rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        order = project.modules.find { _1.name == 'Sales' }.entities.find { _1.name == 'Order' }
        expect(order.attributes.map(&:name)).to include('Number', 'Total')
        expect(order.attributes.find { _1.name == 'Total' }.type).to eq(:decimal)
        expect(project.mendix_version).to eq('10.19.0')
      end

      restored = File.join(dir, 'restored_ruby_app')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      expect(File.read(File.join(restored, 'app', 'models', 'sales', 'order.rb')))
        .to include('mendix_name: \'Total\'')
      expect(File.read(File.join(restored, 'frontend', 'src', 'App.jsx')))
        .to include('// preserved through Mendix')
      expect(File.read(File.join(restored, 'config', 'adapters.rb')))
        .to include('Registry.register_adapter(:document)', "document:\#{name}")
      expect(File).to be_executable(File.join(restored, 'bin', 'server'))

      mendix_tree = File.join(dir, 'mendix_tree')
      switched = File.join(dir, 'switched.mpr')
      Mxrb::Exporter.new(rebuilt, mendix_tree, mode: :mendix).export!
      begin
        ENV['MXRB_OUTPUT_PATH'] = switched
        load File.join(mendix_tree, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      switched_ruby = File.join(dir, 'switched_ruby_app')
      Mxrb::Exporter.new(switched, switched_ruby, mode: :ruby).export!
      expect(File.read(File.join(switched_ruby, 'frontend', 'src', 'App.jsx')))
        .to include('// preserved through Mendix')
    end
  end

  it 'keeps mendix as the default export mode and validates mode names' do
    Dir.mktmpdir('mxrb-mendix-mode-') do |dir|
      source = File.join(dir, 'Sales.mpr')
      root = File.join(dir, 'mendix_source')
      define_source(source)
      Mxrb::Exporter.new(source, root).export!

      expect(File).to exist(File.join(root, 'project.rb'))
      expect(File).not_to exist(File.join(root, 'frontend', 'package.json'))
      expect(File).to exist(
        File.join(root, 'modules', 'Sales', 'domain', 'dtos', 'order_input_dto.rb')
      )
      expect { Mxrb::Exporter.new(source, root, mode: :unknown) }
        .to raise_error(ArgumentError, /mendix or ruby/)
    end
  end

  it 'documents readable run ports and supervises Vite with the server port' do
    Dir.mktmpdir('mxrb-ruby-cli-') do |dir|
      source = File.join(dir, 'Sales.mpr')
      root = File.join(dir, 'sales_app')
      define_source(source)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__),
        '--no-progress', 'export', source, root, '--mode', 'ruby'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('Exported ruby project')

      help_stdout, help_stderr, help_status = Open3.capture3(
        RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'run', '--help'
      )
      expect(help_status).to be_success
      expect(help_stderr).to be_empty
      expect(help_stdout).to include('--server-port PORT', '--client-port PORT')
      expect(help_stdout).to include('--api-port for --server-port', '--no-progress option is optional')

      frontend = File.join(root, 'frontend')
      FileUtils.mkdir_p(File.join(frontend, 'node_modules'))
      supervisor = Mxrb::RubyApp::Supervisor.new(
        root, api_port: 9393, frontend_port: 5393
      )
      expect(Process).to receive(:spawn).with(
        { 'MXRB_ENV' => 'development', 'MXRB_API_PORT' => '9393' }, 'npm', 'run', 'dev', '--',
        '--host', '127.0.0.1', '--port', '5393', chdir: frontend
      ).and_return(12_345)
      expect(supervisor.send(:spawn_frontend)).to eq(12_345)
    end
  end
end
# rubocop:enable Metrics/BlockLength
