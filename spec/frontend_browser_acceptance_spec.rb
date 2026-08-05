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

  def fake_browser(snapshot:, console_errors: [])
    instance_double(MxrbFrontendBrowserAcceptance::Browser).tap do |browser|
      allow(browser).to receive_messages(
        login: nil, navigate: nil, click_selector: nil, click_text: nil,
        wait_for_text: nil, wait_for_selector: nil, wait_for_style: nil, snapshot:,
        console_errors:, close: nil
      )
      allow(browser).to receive(:screenshot) do |path|
        File.binwrite(path, 'stable png')
      end
    end
  end

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
