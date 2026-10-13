# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Generates the TypeScript types and identifiers of the frontend contract.
      module FrontendTypes
        private

        def frontend_types # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          modules = @module_manifests || []
          entities = modules.flat_map { |mod| Array(mod['models']) + Array(mod['dtos']) }
          pages = modules.flat_map { |mod| Array(mod['pages']) }
          enumerations = modules.flat_map { |mod| Array(mod['enumerations']) }
          enumeration_types = enumerations.map do |enumeration|
            name = typescript_identifier(enumeration.fetch('name'))
            values = enumeration.fetch('values', []).map { JSON.generate(_1.fetch('name')) }
            "export type #{name} = #{values.empty? ? 'never' : values.join(' | ')};"
          end
          entity_types = entities.flat_map do |entity|
            name = typescript_identifier(entity.fetch('name'))
            # A member is absent when the user may not read it and null when it is
            # empty; only booleans are never empty.
            attributes = entity.fetch('attributes', []).map do |attribute|
              type = typescript_attribute_type(attribute, enumerations)
              type = "#{type} | null" unless type == 'boolean'
              "  #{JSON.generate(attribute.fetch('name'))}?: #{type};"
            end
            [
              "export interface #{name}Attributes {\n#{attributes.join("\n")}\n}",
              "export type #{name}Record = EntityRecord<#{name}Attributes, #{JSON.generate(entity.fetch('name'))}>;"
            ]
          end
          entity_map = entities.map do |entity|
            "  #{JSON.generate(entity.fetch('name'))}: #{typescript_identifier(entity.fetch('name'))}Record;"
          end
          page_types = pages.map do |page|
            name = typescript_identifier(page.fetch('name'))
            widgets = page.fetch('widgets', []).flat_map { frontend_widget_names(_1) }.uniq
            widget_names = widgets.empty? ? 'never' : widgets.map { JSON.generate(_1) }.join(' | ')
            "export type #{name}WidgetName = #{widget_names};"
          end
          page_map = pages.map do |page|
            name = typescript_identifier(page.fetch('name'))
            qualified = JSON.generate(page.fetch('name'))
            "  #{qualified}: PageDefinition<#{qualified}, #{name}WidgetName>;"
          end
          <<~TS
            // Generated from the Mendix domain, page, widget, effect, and API contracts.
            import type { ComponentType, ReactNode } from 'react';

            export type DecimalValue = { __mxrb_decimal: string };
            export type RuntimeScalar = string | number | boolean | null;
            export type RuntimeValue = RuntimeScalar | EntityRecord | RuntimeValue[] | { [key: string]: RuntimeValue };
            export type RuntimeVariables = Record<string, RuntimeValue | undefined>;

            export interface EntityRecord<
              Attributes extends object = Record<string, RuntimeValue | undefined>,
              Name extends string = string
            > {
              id: string;
              type: Name;
              attributes: Attributes;
              transient?: boolean;
              new_record?: boolean;
              draft_id?: string;
              draft_token?: string;
            }

            export interface WidgetEvent {
              event: string;
              kind: 'microflow' | 'nanoflow' | 'page' | string;
              handler: string;
              arguments?: RuntimeVariables;
              close_page?: boolean;
              settings?: {
                disabled_during_execution?: boolean;
                close_count?: string;
                source?: RuntimeValue;
                confirmation?: { question: string; proceed?: string; cancel?: string };
                progress?: string;
                progress_message?: string;
                asynchronous?: boolean;
                outputs?: Array<{ source: RuntimeValue; expression?: string; attribute?: string; source_attribute?: string }>;
                title?: string;
                link?: { type?: string; value?: string; attribute?: string };
                create?: { entity: string; page?: string; arguments?: RuntimeVariables; association?: string };
              };
            }

            export interface WidgetColumn {
              name?: string;
              attribute?: string;
              caption?: string;
              association_path?: Array<{ association: string; entity: string }>;
              dynamic_text?: string;
              parameters?: string[];
              content?: WidgetDefinition[];
              filter?: string | {
                type?: 'text' | 'number' | 'date' | 'boolean' | 'enum' | 'drop_down';
                operator?: string;
                options?: Array<RuntimeScalar | { value: RuntimeScalar; caption?: string }>;
              };
              sortable?: boolean;
              hidable?: boolean | 'hidden';
              width?: number | 'auto_fit' | 'manual';
              size?: number;
              alignment?: string;
            }

            export interface DataViewSource {
              kind: 'context' | 'association' | 'microflow' | 'nanoflow' | 'listen' | 'native' | string;
              name?: string;
              entity?: string;
              target?: string;
              variable?: {
                kind?: string;
                name?: string;
                sub_key?: string;
                use_all_pages?: boolean;
              };
              steps?: Array<{ association?: string; entity?: string }>;
              mappings?: Array<Record<string, RuntimeValue>>;
            }

            export interface WidgetTab {
              name: string;
              caption?: string;
              widgets?: WidgetDefinition[];
            }

            export interface WidgetSlot {
              path: Array<string | number>;
              role?: string;
              widgets: WidgetDefinition[];
            }

            export type WidgetType =
              #{TYPESCRIPT_WIDGET_TYPES.map { JSON.generate(_1) }.join(' | ')};

            export type DesignValue = true | string | Record<string, string>;

            export interface WidgetOptions {
            #{TYPESCRIPT_WIDGET_OPTIONS.map { |key, type| "  #{key}?: #{type};" }.join("\n")}
              extension?: Record<string, RuntimeValue>;
            }

            export interface WidgetDefinition<Name extends string = string> {
              type: WidgetType;
              name: Name;
              caption?: string;
              options?: WidgetOptions;
              events?: WidgetEvent[];
              children?: WidgetDefinition[];
              body?: WidgetDefinition[];
              footer?: WidgetDefinition[];
              regions?: Record<string, WidgetDefinition[]>;
              slots?: WidgetSlot[];
              header?: WidgetDefinition[];
            }

            // An explicit escape for a declaration outside the widget contract: a
            // type the renderer does not know or options it does not declare.
            export interface ExtensionWidgetDefinition<Name extends string = string> {
              type: string;
              name: Name;
              caption?: string;
              options?: Record<string, unknown>;
              events?: WidgetEvent[];
              children?: AnyWidgetDefinition[];
              body?: AnyWidgetDefinition[];
              footer?: AnyWidgetDefinition[];
              regions?: Record<string, AnyWidgetDefinition[]>;
              slots?: Array<Omit<WidgetSlot, 'widgets'> & { widgets: AnyWidgetDefinition[] }>;
              header?: AnyWidgetDefinition[];
            }

            export type AnyWidgetDefinition = WidgetDefinition | ExtensionWidgetDefinition;

            export interface ValueType {
              kind: string;
              entity?: string;
              enumeration?: string;
            }

            export interface ValueDefinition {
              name: string;
              type?: ValueType;
              required?: boolean;
              default?: string;
            }

            export interface PopupDefinition {
              mode: 'modal' | 'popup';
              width?: number;
              height?: number;
              resizable?: boolean;
              close_action?: string;
            }

            export interface PageOpenOptions {
              drafts?: Array<{ record: EntityRecord; changes: RuntimeVariables }>;
              arguments?: RuntimeVariables;
              location?: 'content' | 'modal' | 'popup';
              title?: string;
            }

            export interface PageDefinition<Name extends string = string, WidgetName extends string = string> {
              layout?: string;
              name: Name;
              title: string;
              parameters?: ValueDefinition[];
              variables?: ValueDefinition[];
              popup?: PopupDefinition;
              autofocus?: string;
              appearance_class?: string;
              appearance_style?: string;
              data_source?: { kind: 'microflow' | 'nanoflow' | string; name: string } | null;
              widgets: Array<WidgetDefinition<WidgetName> | ExtensionWidgetDefinition<WidgetName>>;
            }

            export interface PageComponentProps {
              busy: boolean;
              Widget: ComponentType<PageWidgetProps>;
            }

            export interface PageWidgetProps {
              widget: AnyWidgetDefinition;
              index: number;
              children?: ReactNode;
            }

            export interface AttributeDefinition {
              name: string;
              type: string;
              enumeration?: string;
              localize_date?: boolean;
            }

            export interface EntityDefinition {
              name: string;
              attributes?: AttributeDefinition[];
              generalization?: { target: string };
            }

            export interface EnumerationDefinition {
              id: string;
              name: string;
              values: Array<{ name: string; caption: string; caption_translations?: Record<string, string> }>;
            }

            export interface AssociationDefinition {
              name: string;
              from_entity: string;
              to_entity: string;
              type: string;
            }

            export interface NavigationItem {
              icon?: string | number | { collection: string };
              page?: string;
              caption?: Record<string, string>;
              items?: NavigationItem[];
            }

            export interface NavigationProfile {
              name?: string;
              kind: string;
              home_page?: string;
              items?: NavigationItem[];
            }

            export interface RuntimeModule {
              name: string;
              models?: EntityDefinition[];
              dtos?: EntityDefinition[];
              pages: PageDefinition[];
              enumerations?: EnumerationDefinition[];
              associations?: AssociationDefinition[];
            }

            export interface ApplicationSchema {
              constants?: Record<string, RuntimeValue>;
              module_roles?: string[];
              presentation?: Record<string, PresentationResource>;
              project: { name: string; mendix_version: string };
              languages?: { default?: string; codes?: string[] };
              navigation?: { profiles?: NavigationProfile[] };
              modules: RuntimeModule[];
            }

            export interface PresentationMenuItem {
              caption: string;
              page?: string;
              microflow?: string;
              icon?: string | number | { collection: string };
              items?: PresentationMenuItem[];
              caption_translations?: Record<string, string>;
              action?: WidgetEvent;
            }

            export interface PresentationResource {
              kind: 'menu' | 'snippet' | 'image' | 'layout' | 'icon';
              items?: PresentationMenuItem[];
              widgets?: WidgetDefinition[];
              path?: string;
              character?: number;
              parameters?: Array<string | ValueDefinition>;
              variables?: ValueDefinition[];
            }

            export interface OpenPageEffect {
              type: 'open_page';
              page: string;
              context?: EntityRecord;
              location?: 'content' | 'modal' | 'popup';
              title?: string;
              arguments?: Record<string, RuntimeValue>;
            }

            export interface ShowMessageEffect {
              type: 'show_message';
              message: string;
              level?: string;
              blocking?: boolean;
            }

            export interface RuntimeEffect {
              type: string;
              [key: string]: RuntimeValue | undefined;
            }

            export interface InvocationResult {
              result?: RuntimeValue;
              context?: EntityRecord | null;
              effects?: Array<OpenPageEffect | ShowMessageEffect | RuntimeEffect>;
            }

            export interface EntityCollectionResponse<T extends EntityRecord = EntityRecord> {
              records: T[];
              total?: number;
            }

            export interface Session {
              id?: string;
              username?: string;
              csrf?: string;
              [key: string]: RuntimeValue | undefined;
            }

            export interface LoginResponse {
              csrf: string;
              user?: string;
              roles?: string[];
            }

            export interface ApiFailure extends Error {
              status?: number;
            }

            export type ApiRequest = <T = RuntimeValue | undefined>(
              path: string, options?: RequestInit
            ) => Promise<T>;

            export type NanoflowParameters = RuntimeVariables;
            export type NanoflowMicroflowInvoker = (
              name: string, parameters?: RuntimeVariables
            ) => Promise<unknown>;

            export interface NanoflowMetadata {
              name: string;
              id: string;
              parameters: string[];
            }

            export interface NanoflowExecution<R = RuntimeValue | undefined> {
              result: R;
              variables: NanoflowParameters;
              changes: EntityRecord[];
              messages: Array<{ message: string; level: string; blocking: boolean }>;
              effects: Array<{
                type: string; page?: string; arguments?: NanoflowParameters; count?: number;
                context?: EntityRecord; location?: 'content' | 'modal' | 'popup'; title?: string
              }>;
              validation: Array<{ variable: string; member: string; message: string }>;
            }

            export interface RegisteredNanoflow extends NanoflowMetadata {
              execute(
                parameters: NanoflowParameters, invokeMicroflow?: NanoflowMicroflowInvoker,
                environment?: NanoflowEnvironment
              ): Promise<NanoflowExecution>;
            }

            export interface NanoflowEnvironment {
              pagePath?: string;
              userRoles?: string[];
            }

            #{enumeration_types.join("\n")}

            #{entity_types.join("\n\n")}

            export interface EntityTypeMap {
            #{entity_map.join("\n")}
            }
            export type EntityName = keyof EntityTypeMap;

            #{page_types.join("\n")}

            export interface PageTypeMap {
            #{page_map.join("\n")}
            }
            export type PageName = keyof PageTypeMap;
          TS
        end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def frontend_widget_names(widget)
          nested = Array(widget['children']) + Array(widget['body']) + Array(widget['footer'])
          nested.concat(Array(widget['slots']).flat_map { Array(_1['widgets']) })
          regions = widget.fetch('regions', {})
          nested.concat(regions.values.flat_map { Array(_1) }) if regions.is_a?(Hash)
          Array(widget.dig('options', 'rows')).each do |row|
            nested.concat(Array(row['widgets']))
            nested.concat(Array(row['columns']).flat_map { Array(_1['widgets']) })
            nested.concat(Array(row['cells']).flat_map { Array(_1['widgets']) })
          end
          [widget['name'].to_s, *nested.flat_map { frontend_widget_names(_1) }].reject(&:empty?)
        end

        def typescript_attribute_type(attribute, enumerations)
          if attribute['type'] == 'enum'
            enumeration = enumerations.find do |candidate|
              [candidate['id'], candidate['name']].include?(attribute['enumeration'])
            end
            return typescript_identifier(enumeration['name']) if enumeration
          end

          {
            'boolean' => 'boolean', 'integer' => 'number', 'long' => 'number',
            'autonumber' => 'number', 'decimal' => 'DecimalValue', 'datetime' => 'string',
            'binary' => 'string'
          }.fetch(attribute['type'].to_s, 'string')
        end

        # Qualified names such as A.BC and AB.C share one compact identifier;
        # those keep their segments apart with $, which Mendix names never use.
        def typescript_identifier(value)
          identifier = if typescript_identifier_collisions.include?(value.to_s)
                         value.to_s.split('.').map { _1.gsub(/[^A-Za-z0-9_]/, '') }.join('$')
                       else
                         compact_typescript_identifier(value)
                       end
          return 'MxrbType' if identifier.empty?

          identifier.match?(/\A[A-Za-z_$]/) ? identifier : "Mx#{identifier}"
        end

        def compact_typescript_identifier(value)
          value.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map { _1[0].to_s.upcase + _1[1..].to_s }.join
        end

        def typescript_identifier_collisions
          @typescript_identifier_collisions ||=
            typescript_qualified_names.uniq
                                      .group_by { compact_typescript_identifier(_1) }
                                      .values.select { _1.size > 1 }
                                      .flatten.to_set
        end

        def typescript_qualified_names
          Array(@project&.modules).flat_map do |mod|
            names = mod.entities.map(&:name) + mod.pages.map(&:name) +
                    mod.enumerations.map { _1['Name'].to_s }
            names.map { "#{mod.name}.#{_1}" }
          end
        end
      end
      # rubocop:enable Metrics
    end
  end
end
