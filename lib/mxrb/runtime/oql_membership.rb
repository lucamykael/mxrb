# frozen_string_literal: true

module Mxrb
  module Runtime
    # LIKE and IN readers with SQL three-valued results. LIKE knows only % and _,
    # without ESCAPE, and ignores case; IN compares normalized literal candidates.
    module OqlMembership
      module_function

      def like(read, pattern)
        matcher = Regexp.new("\\A#{translate(pattern)}\\z", Regexp::IGNORECASE | Regexp::MULTILINE)
        lambda do |row|
          value = read.call(row)
          value.nil? ? nil : matcher.match?(value.to_s)
        end
      end

      def translate(pattern)
        pattern.chars.map { |char| { '%' => '.*', '_' => '.' }.fetch(char) { Regexp.escape(char) } }.join
      end

      def within(read, candidates, normalize)
        unknown = candidates.include?(nil)
        known = candidates.compact.map(&normalize)
        lambda do |row|
          value = read.call(row)
          next nil if value.nil?
          next true if known.include?(normalize.call(value))

          unknown ? nil : false
        end
      end
    end
  end
end
