# frozen_string_literal: true

require 'mxrb'

abort 'Usage: serve_without_mpr.rb RUBY_PROJECT' unless ARGV.length == 1
Mxrb::IO::MprFile.singleton_class.prepend(Module.new do
  def open(*)
    raise 'MPR opening is forbidden during real-project browser acceptance'
  end
end)
supervisor = Mxrb::RubyApp::Supervisor.new(
  File.expand_path(ARGV.fetch(0)),
  api_port: Integer(ENV.fetch('MXRB_API_PORT', '19392')),
  frontend_port: Integer(ENV.fetch('MXRB_FRONTEND_PORT', '15173'))
)
trap('INT') { Thread.new { supervisor.shutdown } }
supervisor.start
