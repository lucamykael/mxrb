import type { ReactNode } from 'react';
import type {
  ApiRequest,
  ApplicationSchema,
  EntityRecord,
  RuntimeValue,
  RuntimeVariables,
  WidgetDefinition,
} from '../types';

export type ErrorHandler = (failure: unknown) => void;
export type SaveRecord = (
  record: EntityRecord | null,
  changes: Record<string, RuntimeValue | undefined>,
) => Promise<EntityRecord | null>;
export type InvokeHandler = (
  name: string,
  parameters?: RuntimeVariables,
  contextOverride?: EntityRecord | null,
) => Promise<unknown>;
export type NavigateHandler = (name: string, context?: EntityRecord | null) => Promise<unknown>;
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
