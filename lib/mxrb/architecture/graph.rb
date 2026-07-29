# frozen_string_literal: true

module Mxrb
  module Architecture
    Node = Data.define(:id, :module_name, :kind, :name, :metadata)
    Edge = Data.define(:from, :to, :relation, :metadata)

    class Graph
      attr_reader :nodes, :edges

      def initialize(definition)
        @definition = definition
        @nodes = {}
        @edges = []
        build
      end

      def node_id(module_name, kind, name)
        "#{module_name}::#{kind}::#{name}"
      end

      def find(module_name, kind, name)
        @nodes[node_id(module_name, kind, name)]
      end

      def dependencies_of(node)
        @edges.select { _1.from == node.id }.filter_map { @nodes[_1.to] }
      end

      private

      def build
        @definition.fetch(:modules).each do |mod|
          add_module_nodes(mod)
          add_module_edges(mod)
        end
      end

      def add_module_nodes(mod)
        module_name = mod.fetch(:name)
        {
          entity: mod.fetch(:entities),
          page: mod.fetch(:pages),
          microflow: mod.fetch(:microflows),
          nanoflow: mod.fetch(:nanoflows, []),
          repository: mod.fetch(:repositories, [])
        }.each do |kind, items|
          items.each { add_node(module_name, kind, _1.fetch(:name), _1) }
        end
      end

      def add_module_edges(mod)
        module_name = mod.fetch(:name)
        mod.fetch(:entities).each do |entity|
          from = id(module_name, :entity, entity.fetch(:name))
          entity.fetch(:associations, []).each do |association|
            add_edge(from, ref(module_name, :entity, association.fetch(:target)), :association)
          end
          Array(entity[:lifecycle]).each do |callback|
            add_edge(from, ref(module_name, :microflow, callback.fetch(:handler)), callback.fetch(:event))
          end
        end

        mod.fetch(:pages).each do |page|
          from = id(module_name, :page, page.fetch(:name))
          if (source = page[:data_source])
            add_edge(from, ref(module_name, source.fetch(:kind), source.fetch(:name)), :data_source)
          end
          page.fetch(:events, []).each do |event|
            next if event.fetch(:kind).to_sym == :action

            add_edge(from, ref(module_name, event.fetch(:kind), event.fetch(:handler)), event.fetch(:event),
                     target: event[:target])
          end
          page.fetch(:widgets, []).each do |widget|
            widget.fetch(:events, []).each do |event|
              next if event.fetch(:kind).to_sym == :action

              add_edge(
                from,
                ref(module_name, event.fetch(:kind), event.fetch(:handler)),
                event.fetch(:event),
                target: widget.fetch(:name), widget_type: widget.fetch(:type)
              )
            end
          end
        end

        (mod.fetch(:microflows) + mod.fetch(:nanoflows, [])).each do |flow|
          from = id(module_name, flow.fetch(:runtime) == :client ? :nanoflow : :microflow, flow.fetch(:name))
          flow.fetch(:calls, []).each do |call|
            add_edge(from, ref(module_name, call.fetch(:kind), call.fetch(:name)), :calls)
          end
          flow.fetch(:repositories, []).each do |repository|
            add_edge(from, ref(module_name, :repository, repository), :uses_repository)
          end
        end
      end

      def add_node(module_name, kind, name, metadata)
        identifier = id(module_name, kind, name)
        @nodes[identifier] = Node.new(identifier, module_name, kind, name, metadata)
      end

      def add_edge(from, to, relation, metadata = {})
        @edges << Edge.new(from, to, relation.to_sym, metadata)
      end

      def id(module_name, kind, name)
        node_id(module_name, kind, name)
      end

      def ref(current_module, kind, raw_name)
        text = raw_name.to_s
        if text.include?(".")
          module_name, name = text.split(".", 2)
          id(module_name, kind, name)
        else
          id(current_module, kind, text)
        end
      end
    end
  end
end
