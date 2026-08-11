export type Section =
  | "overview"
  | "pages"
  | "logic"
  | "navigation"
  | "security"
  | "integrations"
  | "settings";

export interface ProjectInfo {
  name: string;
  mendix_version: string;
  format_version: string;
}

export interface Summary {
  modules: number;
  entities: number;
  pages: number;
  microflows: number;
  nanoflows: number;
  integrations: number;
  configurations: number;
}

export interface EntityAttribute {
  name: string;
  type: string;
  required: boolean;
}

export interface Entity {
  id: string;
  name: string;
  qualified_name: string;
  persistent: boolean;
  attributes: EntityAttribute[];
}

export interface Page {
  id: string;
  name: string;
  qualified_name: string;
  title: string;
  url: string;
  layout_id: string | null;
  excluded: boolean;
  allowed_module_roles: string[];
  widget_count: number;
  widget_types: Record<string, number>;
}

export interface Flow {
  id: string;
  name: string;
  qualified_name: string;
  kind: "microflow" | "nanoflow";
  documentation: string;
  allowed_module_roles: string[];
  parameter_count: number;
  object_count: number;
  flow_count: number;
}

export interface ModuleRole {
  name: string;
  description: string;
}

export interface CatalogDocument {
  id: string;
  name: string;
  type: string;
  group: string;
}

export interface ModuleCatalog {
  id: string;
  name: string;
  marketplace: boolean;
  marketplace_guid: string | null;
  marketplace_version: string | null;
  entities: Entity[];
  pages: Page[];
  microflows: Flow[];
  nanoflows: Flow[];
  module_roles: ModuleRole[];
  integrations: CatalogDocument[];
  configurations: CatalogDocument[];
}

export interface NavigationItem {
  caption?: Record<string, string>;
  page?: string;
  microflow?: string;
  icon?: string;
  items?: NavigationItem[];
}

export interface NavigationProfile {
  name: string;
  kind: string;
  offline: boolean;
  home_page?: string;
  home_microflow?: string;
  sign_in_page?: string;
  role_homes: Array<{ role?: string; page?: string; microflow?: string }>;
  items: NavigationItem[];
}

export interface UserRole {
  name: string;
  description: string;
  module_roles: string[];
}

export interface ProjectSetting {
  id: string;
  type: string;
  name: string;
  values: Record<string, string | number | boolean | null>;
}

export interface ProjectCatalog {
  project: ProjectInfo;
  summary: Summary;
  modules: ModuleCatalog[];
  navigation: { profiles: NavigationProfile[] };
  security: { configured: boolean; level: string | null; user_roles: UserRole[] };
  settings: ProjectSetting[];
}
