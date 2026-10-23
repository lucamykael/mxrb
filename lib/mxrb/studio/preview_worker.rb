# frozen_string_literal: true

# Launched only inside PreviewSandbox. All paths below refer to its private
# mount namespace, never the user's saved project or linked Ruby workspace.
require 'json'
require 'mxrb'

File.write('/work/worker-started', '1')
result = begin
  Kernel.load('/work/ruby/project.rb')
  unless File.file?(ENV.fetch('MXRB_OUTPUT_PATH'))
    raise Mxrb::Studio::RubySourceError,
          'project.rb did not generate a model'
  end

  { ok: true }
rescue Exception => e # rubocop:disable Lint/RescueException
  locations = Mxrb::Studio::Protocol.locations_for(e, ['/work/ruby']).map do |location|
    location.merge(file: location.fetch(:file).delete_prefix('/work/ruby/'))
  end
  { ok: false, message: "#{e.class}: #{e.message}", locations: }
end
File.write('/work/result.json', JSON.generate(result))
