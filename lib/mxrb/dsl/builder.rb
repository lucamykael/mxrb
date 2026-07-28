# frozen_string_literal: true

module Mxrb
  module Dsl
    # Entry point for the project-definition DSL.
    # Used by Mxrb.define { ... }
    #
    # Example:
    #
    #   Mxrb.define("MyApp.mpr") do
    #     mendix_version "10.18.0"
    #
    #     module :MyModule do
    #       entity :Customer do
    #         string  :Name, required: true, length: 200
    #         integer :Age
    #         decimal :Balance, default: 0
    #       end
    #
    #       entity :Order do
    #         string   :Description
    #         datetime :OrderDate
    #         association :Customer, type: :Reference
    #       end
    #
    #       page :CustomerList do
    #         layout "Atlas_Default"
    #         title  "Customers"
    #       end
    #
    #       microflow :CreateCustomer do
    #         parameter :NewCustomer, type: :Customer
    #         return_type :Customer
    #       end
    #     end
    #   end
    #
    class Builder
      def initialize(path)
        @path           = path
        @mendix_version = "10.18.0"
        @modules        = []
      end

      def mendix_version(v)
        @mendix_version = v
      end

      def module(name, &block)
        mod = ModuleBuilder.new(name)
        mod.instance_eval(&block) if block
        @modules << mod
      end

      def build!
        # Will generate the .mpr from scratch or update an existing one.
        # For now, emits the definition as a summary.
        puts "[mxrb] Building #{@path} (Mendix #{@mendix_version})"
        @modules.each do |m|
          puts "  module #{m.name}"
          m.entities.each    { |e| puts "    entity       #{e[:name]}  (#{e[:attributes].size} attrs)" }
          m.pages.each       { |p| puts "    page         #{p[:name]}" }
          m.microflows.each  { |f| puts "    microflow    #{f[:name]}" }
        end
        self
      end

      # Expose for inspection / code generation
      def definition
        { version: @mendix_version, modules: @modules.map(&:to_h) }
      end
    end

    class ModuleBuilder
      attr_reader :name, :entities, :pages, :microflows, :associations

      def initialize(name)
        @name         = name.to_s
        @entities     = []
        @pages        = []
        @microflows   = []
        @associations = []
      end

      def entity(name, &block)
        eb = EntityBuilder.new(name)
        eb.instance_eval(&block) if block
        @entities << eb.to_h
      end

      def page(name, &block)
        pb = PageBuilder.new(name)
        pb.instance_eval(&block) if block
        @pages << pb.to_h
      end

      def microflow(name, &block)
        fb = MicroflowBuilder.new(name)
        fb.instance_eval(&block) if block
        @microflows << fb.to_h
      end

      def to_h
        { name: @name, entities: @entities, pages: @pages, microflows: @microflows }
      end
    end

    class EntityBuilder
      ATTR_TYPES = %i[string integer long decimal boolean datetime autonumber hashstring enum].freeze

      attr_reader :name

      def initialize(name)
        @name        = name.to_s
        @attributes  = []
        @persistable = true
        @doc         = ""
      end

      ATTR_TYPES.each do |type|
        define_method(type) do |attr_name, **opts|
          @attributes << { name: attr_name.to_s, type: type, **opts }
        end
      end

      def non_persistent!  = (@persistable = false)
      def documentation(d) = (@doc = d)

      def to_h
        { name: @name, persistable: @persistable, documentation: @doc, attributes: @attributes }
      end
    end

    class PageBuilder
      def initialize(name)
        @name   = name.to_s
        @layout = "Atlas_Default"
        @title  = name.to_s
        @popup  = false
      end

      def layout(l) = (@layout = l)
      def title(t)  = (@title = t)
      def popup!    = (@popup = true)

      def to_h
        { name: @name, layout: @layout, title: @title, popup: @popup }
      end
    end

    class MicroflowBuilder
      def initialize(name)
        @name        = name.to_s
        @parameters  = []
        @return_type = nil
        @doc         = ""
      end

      def parameter(name, type:)
        @parameters << { name: name.to_s, type: type.to_s }
      end

      def return_type(t) = (@return_type = t.to_s)
      def documentation(d) = (@doc = d)

      def to_h
        { name: @name, parameters: @parameters, return_type: @return_type, documentation: @doc }
      end
    end
  end
end
