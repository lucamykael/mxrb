# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Page < Unit
      unit_type "Mxmodels.Pages.Page"

      attr_accessor :name, :title, :layout, :documentation, :popup

      def decode(blob)
        @_raw          = blob
        @name          = "Page_#{@id}"
        @title         = ""
        @layout        = "Atlas_Default"
        @documentation = ""
        @popup         = false
      end

      def encode = @_raw || ""

      def inspect
        "#<Mxrb::Page id=#{@id} name=#{@name.inspect} layout=#{@layout.inspect}>"
      end
    end
  end
end
