# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

load File.expand_path('../script/frontend_browser_acceptance', __dir__)

# rubocop:disable Metrics/BlockLength
RSpec.describe MxrbFrontendBrowserAcceptance::Runner do
  let(:config) do
    {
      'name' => 'authenticated-smoke',
      'viewport' => { 'width' => 1280, 'height' => 720 },
      'pages' => [{
        'name' => 'home', 'path' => '/', 'click_selector' => '#menu',
        'click_text' => 'Orders', 'text' => ['Welcome'], 'selectors' => ['main'],
        'styles' => [{ 'selector' => 'body', 'property' => 'margin-top', 'equals' => '0px' }]
      }]
    }
  end
  let(:snapshot) do
    {
      'title' => 'App', 'path' => '/',
      'viewport' => { 'width' => 1280, 'height' => 720 },
      'elements' => [{ 'tag' => 'main', 'text' => 'Welcome' }]
    }
  end

  def fake_browser(snapshot:, console_errors: [], resource_errors: []) # rubocop:disable Metrics/MethodLength
    instance_double(MxrbFrontendBrowserAcceptance::Browser).tap do |browser|
      allow(browser).to receive_messages(
        login: nil, navigate: nil, click_selector: nil, click_text: nil,
        measure_click: { 'duration_ms' => 42.0 },
        input_value: nil, measure_input: { 'duration_ms' => 35.0 },
        select_option: nil, measure_select: { 'duration_ms' => 30.0 },
        audit_widgets: { 'count' => 12, 'render_ms' => 80.0 },
        wait_for_text: nil, wait_for_selector: nil, wait_for_count: nil,
        wait_for_absence: nil, wait_for_idle: nil, wait_for_style: nil, snapshot:,
        settle_healthy_media: [], widget_resource_errors: resource_errors,
        console_errors:, diagnostics: {}, close: nil
      )
      allow(browser).to receive(:screenshot) do |path|
        File.binwrite(path, 'stable png')
      end
    end
  end # rubocop:enable Metrics/MethodLength

  def run(browser, root, baseline: nil, update_baseline: false)
    described_class.new(
      config:, base_url: 'http://127.0.0.1:8080/', username: 'MxAdmin', password: 'secret',
      output_dir: File.join(root, 'evidence'), baseline:, update_baseline:, browser:
    ).run
  end

  it 'updates and then matches deterministic authenticated visual evidence' do
    Dir.mktmpdir do |root|
      baseline = File.join(root, 'baseline.json')
      browser = fake_browser(snapshot:)
      updated = run(browser, root, baseline:, update_baseline: true)
      matched = run(fake_browser(snapshot:), root, baseline:)

      expect(updated.dig(:baseline, 'mode')).to eq('updated')
      expect(matched.dig(:baseline, 'mode')).to eq('matched')
      expect(matched).to include(passed: true, authenticated: true, console_errors: [])
      expect(File).to exist(File.join(root, 'evidence', 'home.png'))
      expect(browser).to have_received(:wait_for_style).with(
        'selector' => 'body', 'property' => 'margin-top', 'equals' => '0px'
      )
    end
  end

  it 'reports changed snapshots without replacing the baseline' do
    Dir.mktmpdir do |root|
      baseline = File.join(root, 'baseline.json')
      run(fake_browser(snapshot:), root, baseline:, update_baseline: true)
      changed = snapshot.merge('title' => 'Changed')
      report = run(fake_browser(snapshot: changed), root, baseline:)

      expect(report).to include(passed: false)
      expect(report.fetch(:error)).to include('visual baseline differs for: home')
    end
  end

  it 'rejects visible widget failures and browser exceptions' do
    Dir.mktmpdir do |root|
      broken = snapshot.merge(
        'elements' => [{ 'tag' => 'div', 'text' => "Could not render widget 'Demo.bad'" }]
      )
      visible_failure = run(fake_browser(snapshot: broken), root)
      browser_failure = run(fake_browser(snapshot:, console_errors: ['Uncaught Error']), root)

      expect(visible_failure.fetch(:error)).to include('visible widget render failure')
      expect(browser_failure.fetch(:error)).to include('browser exceptions: Uncaught Error')
    end
  end

  it 'rejects failed Marketplace widget resources' do
    Dir.mktmpdir do |root|
      errors = [{ 'url' => 'http://127.0.0.1/widgets/icon.svg', 'status' => 404 }]
      report = run(fake_browser(snapshot:, resource_errors: errors), root)

      expect(report).to include(passed: false)
      expect(report.fetch(:error)).to include('widget resource failures', 'icon.svg')
    end
  end

  it 'rejects the generic Mendix runtime error dialog' do
    Dir.mktmpdir do |root|
      messages = [
        'An error occurred, please contact your system administrator.',
        'Executing runtime operation failed for security reasons: operation-id'
      ]

      messages.each do |message|
        broken = snapshot.merge('elements' => [{ 'tag' => 'p', 'text' => message }])
        expect(run(fake_browser(snapshot: broken), root).fetch(:error))
          .to include('visible widget render failure')
      end
    end
  end

  it 'runs an unauthenticated multi-step interaction flow in order' do
    Dir.mktmpdir do |root|
      config['authentication'] = false
      config.fetch('pages').first.replace(
        'name' => 'sudoku', 'path' => '/',
        'steps' => [
          { 'click_text' => 'Start easy game' },
          { 'wait_for_count' => { 'selector' => '.sd-cell', 'equals' => 81 } },
          { 'measure_click' => { 'selector' => '.sd-cell', 'index' => 72, 'max_ms' => 250 } },
          { 'wait_for_selector' => '.sd-cell.sd-sel' },
          { 'wait_for_absence' => '[role="alert"]' }
        ]
      )
      browser = fake_browser(snapshot:)

      report = run(browser, root)

      expect(report).to include(passed: true, authenticated: false)
      expect(browser).not_to have_received(:login)
      expect(browser).to have_received(:click_text).with('Start easy game').ordered
      expect(browser).to have_received(:wait_for_count)
        .with('selector' => '.sd-cell', 'equals' => 81).ordered
      expect(browser).to have_received(:measure_click)
        .with('selector' => '.sd-cell', 'index' => 72, 'max_ms' => 250).ordered
      expect(browser).to have_received(:wait_for_selector).with('.sd-cell.sd-sel').ordered
      expect(browser).to have_received(:wait_for_absence).with('[role="alert"]').ordered
      expect(report.dig(:pages, 0, 'measurements', 0, 'result', 'duration_ms')).to eq(42.0)
    end
  end

  it 'rejects ambiguous or empty declarative steps' do
    Dir.mktmpdir do |root|
      config['authentication'] = false
      config.fetch('pages').first.replace(
        'name' => 'invalid', 'steps' => [{ 'click_text' => 'Easy', 'navigate' => '/' }]
      )

      report = run(fake_browser(snapshot:), root)

      expect(report).to include(passed: false)
      expect(report.fetch(:error)).to include('exactly one action')
    end
  end
end

RSpec.describe MxrbFrontendBrowserAcceptance::Browser do
  it 'collects exceptions, console.error/assert calls, and Console error messages' do
    events = [
      { 'method' => 'Runtime.exceptionThrown', 'params' => { 'exceptionDetails' => { 'text' => 'boom' } } },
      { 'method' => 'Runtime.consoleAPICalled', 'params' => {
        'type' => 'error', 'args' => [{ 'value' => 'widget failed' }, { 'description' => 'Error: bad' }]
      } },
      { 'method' => 'Runtime.consoleAPICalled', 'params' => { 'type' => 'log', 'args' => [] } },
      { 'method' => 'Console.messageAdded', 'params' => {
        'message' => { 'level' => 'error', 'text' => 'console domain failure' }
      } },
      { 'method' => 'Console.messageAdded', 'params' => { 'message' => { 'level' => 'warning' } } }
    ]
    browser = described_class.allocate
    browser.instance_variable_set(:@client, instance_double(
                                              MxrbFrontendBrowserAcceptance::CdpClient,
                                              events:
                                            ))
    browser.instance_variable_set(:@console_event_index, 0)
    browser.instance_variable_set(:@console_errors, [])

    expect(browser.console_errors).to eq(
      ['boom', 'widget failed Error: bad', 'console domain failure']
    )
    expect(browser.console_errors.length).to eq(3)
  end
end

RSpec.describe MxrbFrontendBrowserAcceptance::CdpClient do
  it 'correlates responses while retaining intervening browser events' do
    transport = instance_double(MxrbFrontendBrowserAcceptance::ChromiumTransport)
    event = { method: 'Runtime.exceptionThrown', params: { exceptionDetails: { text: 'boom' } } }
    allow(transport).to receive(:write)
    allow(transport).to receive(:read).and_return(
      JSON.generate(event), JSON.generate(id: 1, result: { value: true })
    )

    client = described_class.new(transport)
    expect(client.call('Runtime.evaluate')).to eq('value' => true)
    expect(client.events).to eq([JSON.parse(JSON.generate(event))])
    expect(transport).to have_received(:write).with(id: 1, method: 'Runtime.evaluate', params: {})
  end

  it 'turns CDP error responses into acceptance failures' do
    transport = instance_double(MxrbFrontendBrowserAcceptance::ChromiumTransport)
    allow(transport).to receive(:write)
    allow(transport).to receive(:read).and_return(JSON.generate(id: 1, error: { message: 'bad' }))

    expect { described_class.new(transport).call('Page.navigate') }
      .to raise_error(MxrbFrontendBrowserAcceptance::Failure, /CDP Page.navigate failed/)
  end
end

RSpec.describe MxrbFrontendBrowserAcceptance::Browser do
  it 'reports HTTP and transport failures for Marketplace widget resources only' do
    browser = described_class.allocate
    events = [
      {
        'method' => 'Network.responseReceived',
        'params' => { 'response' => { 'url' => 'http://app/widgets/icon.svg', 'status' => 404 } }
      },
      {
        'method' => 'Network.responseReceived',
        'params' => { 'response' => { 'url' => 'http://app/favicon.ico', 'status' => 404 } }
      },
      {
        'method' => 'Network.requestWillBeSent',
        'params' => { 'requestId' => 'failed',
                      'request' => { 'url' => 'http://app/widgets%2Fvideo.mp4' } }
      },
      {
        'method' => 'Network.loadingFailed',
        'params' => { 'requestId' => 'failed', 'errorText' => 'net::ERR_FAILED' }
      }
    ]
    browser.instance_variable_set(
      :@client, instance_double(MxrbFrontendBrowserAcceptance::CdpClient, events:)
    )
    browser.instance_variable_set(:@network_event_index, 0)
    allow(browser).to receive(:evaluate).with('true').and_return(true)

    expect(browser.widget_resource_errors).to contain_exactly(
      { 'url' => 'http://app/widgets/icon.svg', 'status' => 404 },
      { 'url' => 'http://app/widgets%2Fvideo.mp4', 'error' => 'net::ERR_FAILED' }
    )
    expect(browser.widget_resource_errors).to be_empty
  end

  it 'waits for positive and negative computed-style contracts' do
    browser = described_class.allocate
    allow(browser).to receive(:wait).and_return(true)

    browser.wait_for_style(
      'selector' => 'body', 'property' => 'margin-top', 'equals' => '0px'
    )
    browser.wait_for_style(
      'selector' => '.mxrb-page-header', 'property' => 'background-image', 'not' => 'none'
    )

    expect(browser).to have_received(:wait).twice
  end

  it 'supports indexed clicks, exact counts, and absence assertions' do
    browser = described_class.allocate
    allow(browser).to receive(:wait).and_return(true)

    browser.click_selector('selector' => '.sd-cell', 'index' => 73)
    browser.wait_for_count('selector' => '.sd-cell', 'equals' => 81)
    browser.wait_for_absence('[role="alert"]')

    expect(browser).to have_received(:wait).exactly(3).times
  end

  it 'enforces measured click latency budgets' do
    browser = described_class.allocate
    allow(browser).to receive(:evaluate).and_return(
      'duration_ms' => 48.5, 'requests' => [{ 'url' => '/api/action', 'duration_ms' => 20.0 }]
    )

    result = browser.measure_click('selector' => '.cell', 'index' => 2, 'max_ms' => 50)
    expect(result).to include('duration_ms' => 48.5, 'selector' => '.cell', 'index' => 2)

    allow(browser).to receive(:evaluate).and_return('duration_ms' => 51.0, 'requests' => [])
    expect { browser.measure_click('selector' => '.cell', 'max_ms' => 50) }
      .to raise_error(MxrbFrontendBrowserAcceptance::Failure, /budget 50.0ms/)
  end

  it 'sets and measures controlled inputs and audits rendered widgets' do
    browser = described_class.allocate
    allow(browser).to receive(:wait).and_return(true)
    allow(browser).to receive(:evaluate).and_return(
      { 'duration_ms' => 40.0, 'requests' => [] },
      { 'duration_ms' => 30.0, 'requests' => [] },
      {
        'count' => 3, 'invisible' => [], 'failures' => [],
        'types' => { 'text_box' => 1, 'button' => 2 },
        'render_ms' => 120.0, 'longest_task_ms' => 0
      }
    )

    browser.input_value('selector' => 'input', 'value' => 'Ada')
    measured = browser.measure_input(
      'selector' => 'input', 'value' => 'Grace', 'max_ms' => 50
    )
    browser.select_option('selector' => 'select', 'option_index' => 1)
    selected = browser.measure_select(
      'selector' => 'select', 'option_index' => 1, 'max_ms' => 50
    )
    audit = browser.audit_widgets('min_count' => 3, 'max_render_ms' => 200)

    expect(browser).to have_received(:wait).twice
    expect(measured).to include('duration_ms' => 40.0, 'selector' => 'input')
    expect(selected).to include('duration_ms' => 30.0, 'selector' => 'select')
    expect(audit).to include('count' => 3, 'render_ms' => 120.0)
  end

  it 'fails widget audits on placeholders, invisible output, and render budgets' do
    browser = described_class.allocate
    allow(browser).to receive(:evaluate).and_return(
      {
        'count' => 1, 'invisible' => [], 'failures' => ['Could not render widget'],
        'types' => {}, 'render_ms' => 10.0, 'longest_task_ms' => 0
      }
    )
    expect { browser.audit_widgets({}) }
      .to raise_error(MxrbFrontendBrowserAcceptance::Failure, /render failures/)
  end
end

RSpec.describe MxrbFrontendBrowserAcceptance::CLI do
  it 'reads plain and JSON credential files without putting secrets in options' do
    Dir.mktmpdir do |root|
      plain = File.join(root, 'plain')
      json = File.join(root, 'credentials.json')
      File.write(plain, "plain-secret\n")
      File.write(json, JSON.generate(admin_password: 'json-secret'))

      expect(described_class.password(plain)).to eq('plain-secret')
      expect(described_class.password(json)).to eq('json-secret')
    end
  end

  it 'uses the dedicated environment variable when no password file is supplied' do
    previous = ENV.fetch('MXRB_BROWSER_PASSWORD', nil)
    ENV['MXRB_BROWSER_PASSWORD'] = 'environment-secret'
    expect(described_class.password(nil)).to eq('environment-secret')
  ensure
    previous ? ENV['MXRB_BROWSER_PASSWORD'] = previous : ENV.delete('MXRB_BROWSER_PASSWORD')
  end
end
# rubocop:enable Metrics/BlockLength
