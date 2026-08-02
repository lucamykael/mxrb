# frozen_string_literal: true

module Mxrb
  module Runtime
    # Resolves a version-compatible local JDK without invoking a version manager shim.
    module JavaLocator
      module_function

      def resolve(major, configured: nil)
        candidates = [configured, ENV['MXRB_JAVA_HOME'], ENV['JAVA_HOME']]
                     .compact.reject { _1.to_s.empty? }
        candidates.concat(installed(major))
        candidates.map { File.expand_path(_1) }
                  .find { File.executable?(File.join(_1, 'bin', 'java')) }
      end

      def installed(major)
        %w[.asdf/installs/java .local/share/mise/installs/java].flat_map do |root|
          Dir.glob(File.join(Dir.home, root, '*')).select do |path|
            File.basename(path).match?(/(?:\A|[-_])#{Regexp.escape(major.to_s)}(?:[._-]|\z)/)
          end
        end.sort.reverse
      end
    end
  end
end
