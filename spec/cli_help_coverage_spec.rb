# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::CLI::Help do
  it 'renders welcome variants, overview, and both command listings' do
    unavailable = double(available?: false)
    available = double(available?: true, latest: '2.0.0', installed: '1.0.0')
    expect(described_class.welcome).to include('Common next steps:', 'mxrb --help')
    expect(described_class.welcome(release: unavailable)).not_to include('Update available')
    expect(described_class.welcome(release: available)).to include(
      'Update available: 2.0.0', 'mxrb changelog', 'mxrb update'
    )
    expect(described_class.overview).to include(
      'Start a new project:', 'Convert and run', 'Discovery:', 'Updates:'
    )

    all = described_class.commands
    expect(all).to include('Available MXRB commands', 'diagram-er', 'uml', 'env', 'run', 'test')
    expect(described_class.commands('diagram-er')).to include(
      'diagram-er up', 'diagram-er down', 'diagram-er status', 'diagram-er destroy'
    )
  end

  it 'documents diagram-er parent and lifecycle commands plus its hidden alias' do
    parent = described_class.command('diagram-er')
    expect(parent).to include(
      'Usage: mxrb diagram-er FILE.mpr', '--module NAME', '--output FILE',
      '--port PORT', '--force', 'Subcommands:', 'SUBCOMMAND --help'
    )
    %w[up down status destroy].each do |action|
      detail = described_class.command(['diagram-er', action])
      expect(detail).to include("Usage: mxrb diagram-er #{action}", 'Parent help: mxrb diagram-er --help')
    end
    expect(described_class.command('domain-model')).to include('Usage: mxrb diagram-er')
  end

  it 'documents UML, environment profiles, run aliases, and test profiles' do
    expect(described_class.command('uml')).to include(
      'Usage: mxrb uml FILE.mpr', '--export TYPE', '--format FORMAT', '--module NAME',
      '--microflow NAME', '--root NAME', '--depth N', '--port PORT'
    )
    expect(described_class.command('env')).to include(
      'Usage: mxrb env', '--environment NAME', '--json', 'values remain hidden'
    )
    expect(described_class.command('run')).to include(
      'Usage: mxrb run', '--host HOST', '--server-port PORT', '--client-port PORT',
      '--environment NAME', '--no-frontend', '--api-port', '--no-progress'
    )
    expect(described_class.command('test')).to include(
      'Usage: mxrb test', '--environment NAME', 'selected profile'
    )
  end

  it 'handles detailed, plain, unknown, and scaffold commands' do
    expect(described_class.command(%w[cache warm])).to include(
      'Usage: mxrb cache warm', 'Parent help: mxrb cache --help'
    )
    expect(described_class.command('validate')).to include('Usage: mxrb validate', 'Validate MPR structure')
    expect(described_class.command('missing')).to include(
      'No help is registered for `mxrb missing`', 'mxrb --commands'
    )

    scaffold = Mxrb::Scaffold::Help::COMMANDS.keys.find { !described_class::COMMANDS.key?(_1) }
    expect(described_class.command(scaffold)).to include('Usage:')
    expect(described_class.known?('run')).to be(true)
    expect(described_class.known?(scaffold)).to be(true)
    expect(described_class.known?(:missing)).to be(false)
    expect(described_class.scaffold_command?(scaffold)).to be(true)
    expect(described_class.scaffold_command?('query')).to be(false)
    expect(described_class.scaffold_commands.map(&:name)).to include(scaffold)
    expect(described_class.scaffold_commands.map(&:name)).not_to include('query', 'design')
  end

  it 'renders group headings when subcommand details are unavailable' do
    expect(described_class.group_commands('cache', heading: 'Cache actions:')).to start_with('Cache actions:')
    stub_const('Mxrb::CLI::Help::SUBCOMMAND_HELP', {})
    output = described_class.group_commands('cache')
    expect(output).to include('Subcommands for `mxrb cache`:', 'cache status')
  end
end
# rubocop:enable Metrics/BlockLength
