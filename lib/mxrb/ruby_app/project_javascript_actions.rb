# frozen_string_literal: true

module Mxrb
  module RubyApp
    # The project's own JavaScript actions that the exported nanoflows call:
    # javascriptsource/<module>/actions/<Name>.js, with the function's parameters
    # in call order and their JSDoc types, as Studio Pro generates them. MXRB
    # distributes none of this code.
    module ProjectJavaScriptActions
      Action = Data.define(:name, :directory, :file, :function, :parameters, :packages)

      # Imports every action may use: the client global and Big, which the
      # generated frontend provides.
      PROVIDED = %w[mx-global big.js].freeze

      module_function

      def find(root, names)
        names.sort.filter_map do |name|
          module_name, action = name.split('.', 2)
          next unless action

          directory = File.join(root, 'javascriptsource', module_name.downcase, 'actions')
          file = File.join(directory, "#{action}.js")
          found = read(name, directory, file, action) if File.file?(file)
          found if found && resolvable?(found)
        end
      end

      # Every package an action imports must ship in its own node_modules; an
      # action for another platform (react-native) is left out.
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
        Action.new(name:, directory:, file:, function: action, parameters:, packages: packages(source))
      end

      # The bare module names an action imports beyond those the frontend provides.
      def packages(source)
        source.scan(/^\s*import\s+(?:[^'"]*?\s+from\s+)?["']([^"'.][^"']*)["']/).flatten.uniq - PROVIDED
      end
    end
  end
end
