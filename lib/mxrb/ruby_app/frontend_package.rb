# frozen_string_literal: true

require 'json'

module Mxrb
  module RubyApp
    # The npm packages the generated frontend bridge imports and builds with.
    # The exporter writes them into frontend/package.json; the supervisor checks
    # that an older package.json kept beside a newer bridge still declares and
    # installs them, instead of letting Vite fail on a missing import.
    module FrontendPackage
      DEPENDENCIES = {
        'react' => '^19.2.8', 'react-dom' => '^19.2.8',
        'react-router-dom' => '^7.18.2', 'date-fns' => '^4.1.0', 'decimal.js' => '^10.6.0',
        'big.js' => '^6.2.2',
        'plotly.js-dist-min' => '3.0.1',
        'js-base64' => '3.7.7'
      }.freeze
      DEV_DEPENDENCIES = {
        '@eslint/js' => '^10.0.1',
        '@testing-library/jest-dom' => '^7.0.1',
        '@testing-library/react' => '^16.3.2',
        '@testing-library/user-event' => '^14.6.4',
        '@types/big.js' => '^6.2.2', '@types/node' => '^26.2.0', '@types/react' => '^19.2.18',
        '@types/react-dom' => '^19.2.4', '@vitejs/plugin-react' => '^6.0.5',
        'eslint' => '^10.8.1', 'eslint-plugin-react-hooks' => '^7.1.1',
        'globals' => '^17.11.0',
        'jsdom' => '^30.0.1', 'prettier' => '^3.9.6',
        'sass-embedded' => '^1.90.0', 'typescript' => '^6.0.3',
        'typescript-eslint' => '^8.67.0', 'vite' => '^8.2.1', 'vitest' => '^4.1.11'
      }.freeze

      module_function

      # The packages a frontend directory's package.json leaves undeclared.
      def undeclared(directory)
        declared = declared_packages(File.join(directory, 'package.json'))
        (DEPENDENCIES.keys + DEV_DEPENDENCIES.keys) - declared
      end

      # The runtime packages a frontend directory has not installed.
      def uninstalled(directory)
        DEPENDENCIES.keys.reject { File.directory?(File.join(directory, 'node_modules', _1)) }
      end

      def declared_packages(path)
        package = JSON.parse(File.read(path))
        %w[dependencies devDependencies].flat_map { package.fetch(_1, {}).keys }
      rescue JSON::ParserError, Errno::ENOENT
        []
      end
    end
  end
end
