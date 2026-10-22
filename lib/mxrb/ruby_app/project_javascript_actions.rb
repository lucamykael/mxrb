# frozen_string_literal: true

module Mxrb
  module RubyApp
    # The project's own JavaScript actions that the exported nanoflows call:
    # javascriptsource/<module>/actions/<Name>.js, with the function's parameters
    # in call order and their JSDoc types, as Studio Pro generates them. MXRB
    # distributes none of this code.
    module ProjectJavaScriptActions
      Action = Data.define(:name, :directory, :file, :function, :parameters, :packages, :web_branch)

      # Imports every action may use: the client global and Big, which the
      # generated frontend provides.
      PROVIDED = %w[mx-global big.js].freeze

      # A package of the React Native platform: react-native itself, a
      # react-native-* library or a scoped one (@scope/react-native-*,
      # @react-native-*/name).
      REACT_NATIVE = %r{(?:\A@?|/)react-native(?:\z|[-/])}
      # The platform check of an action that also implements the web: its
      # React Native imports are only used on a phone.
      WEB_BRANCH = /navigator\.product\s*===?\s*["']ReactNative["']/

      module_function

      # The actions that run in the browser from their own source: those whose
      # packages ship in their node_modules and that do not target React Native.
      def find(root, names)
        actions(root, names).select { resolvable?(_1) && !react_native?(_1) }
      end

      # The names of the actions whose implementation targets React Native
      # only: the browser cannot run them, so the export needs an adapter or fails.
      def react_native(root, names)
        actions(root, names).select { react_native?(_1) }.map(&:name)
      end

      def actions(root, names)
        names.sort.filter_map do |name|
          module_name, action = name.split('.', 2)
          next unless action

          directory = File.join(root, 'javascriptsource', module_name.downcase, 'actions')
          file = File.join(directory, "#{action}.js")
          read(name, directory, file, action) if File.file?(file)
        end
      end

      def react_native?(action) = !action.web_branch && action.packages.any? { _1.match?(REACT_NATIVE) }

      # Every package an action imports must ship in its own node_modules.
      def resolvable?(action)
        action.packages.all? do |package|
          root = package.start_with?('@') ? package.split('/').first(2).join('/') : package.split('/').first
          File.directory?(File.join(action.directory, 'node_modules', root))
        end
      end

      def read(name, directory, file, action)
        source = File.read(file, encoding: 'UTF-8')
        signature = source.match(/export\s+(?:async\s+)?function\s+#{Regexp.escape(action)}\s*\(([^)]*)\)/)
        return unless signature

        types = source.scan(/@param\s+\{([^}]+)\}\s+(\w+)/).to_h { |type, parameter| [parameter, type] }
        parameters = signature[1].split(',').map(&:strip).reject(&:empty?).map do |parameter|
          { name: parameter, type: types.fetch(parameter, '') }
        end
        Action.new(name:, directory:, file:, function: action, parameters:, packages: packages(source),
                   web_branch: source.match?(WEB_BRANCH))
      end

      # The bare module names an action imports beyond those the frontend provides.
      def packages(source)
        source.scan(/^\s*import\s+(?:[^'"]*?\s+from\s+)?["']([^"'.][^"']*)["']/).flatten.uniq - PROVIDED
      end
    end
  end
end
