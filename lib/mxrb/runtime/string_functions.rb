# frozen_string_literal: true

module Mxrb
  module Runtime
    module Native
      # Mendix string positions count Java UTF-16 units, not Ruby codepoints.
      module StringFunctions
        private

        def utf16_units(value)
          value.to_s.encode('UTF-16LE').unpack('v*')
        end

        def string_find(value, needle, start = 0)
          text = utf16_units(value)
          target = utf16_units(needle)
          first = [Integer(start), 0].max
          return [first, text.length].min if target.empty?

          (first..(text.length - target.length)).find { text[_1, target.length] == target } || -1
        end

        def string_find_last(value, needle)
          text = utf16_units(value)
          target = utf16_units(needle)
          (text.length - target.length).downto(0).find { text[_1, target.length] == target } || -1
        end

        def substring(value, start, length = nil)
          text = utf16_units(value)
          first = Integer(start)
          count = length.nil? ? text.length - first : Integer(length)
          if first.negative? || count.negative? || first + count > text.length
            raise NativeRuntimeError, 'substring range is outside the string'
          end

          text.slice(first, count).pack('v*').force_encoding('UTF-16LE').encode('UTF-8')
        end
      end
    end
  end
end
