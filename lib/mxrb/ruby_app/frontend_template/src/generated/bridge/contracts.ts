import type { ReactNode } from 'react';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  RuntimeValue,
  RuntimeVariables,
  WidgetDefinition,
  PageOpenOptions,
  AnyWidgetDefinition,
} from '../types';

// The renderer reads every widget as served data: it renders the types it
// knows and reports the rest, so an explicit extension declaration renders
// through the same path as a contract one.
export const servedWidget = (widget: AnyWidgetDefinition): WidgetDefinition =>
  widget as WidgetDefinition;

export type ErrorHandler = (failure: unknown) => void;
export type SaveRecord = (
  record: EntityRecord | null,
  changes: Record<string, RuntimeValue | undefined>,
) => Promise<EntityRecord | null>;
export type InvokeHandler = (
  name: string,
  parameters?: RuntimeVariables,
  contextOverride?: EntityRecord | null,
  options?: { asynchronous?: boolean },
) => Promise<unknown>;
export type NavigateHandler = (
  name: string,
  context?: EntityRecord | null,
  options?: PageOpenOptions,
) => Promise<unknown>;
export type SelectRecord = (record: EntityRecord | null) => void;

export interface WidgetRuntimeProps {
  widget: WidgetDefinition;
  children?: ReactNode;
  moduleName: string;
  invoke: InvokeHandler;
  invokeNanoflow: InvokeHandler;
  navigate: NavigateHandler;
  context?: EntityRecord | null;
  pageContext: EntityRecord | null;
  revision: number;
  schema: ApplicationSchema;
  request: ApiRequest;
  saveRecord: SaveRecord;
  onError: ErrorHandler;
  onMutation: () => void;
  onSelectRecord: SelectRecord;
}
