# Native Ruby coverage

This is the source of truth for expansion of the Ruby → Mendix compiler. A
surface is `native` only after tests cover creation, update, removal, reopening
the MPR, and recompilation without changing native identities.

States are `native`, `partial`, `preserved_native`, and `runtime_only`.

| Surface | State |
|---|---|
| Entities, non-persistent DTOs and attributes | native |
| Local and cross-module associations | native |
| Enumeration definitions | native |
| Constants and entity access rules | preserved_native |
| Indexes, system members, generalization and OQL views | preserved_native |
| Entity lifecycle | partial |
| Module roles and project security | preserved_native |
| Microflows, nanoflows and core pages | partial |
| Layouts, snippets, building blocks and menus | preserved_native |
| Navigation and pluggable widgets | partial |
| Scheduled events | preserved_native |
| REST, OData, App/Web Services and mappings | preserved_native |
| Java custom actions and external connectors | runtime_only |
| Workflows and task pages | preserved_native |
| Settings, themes, design system and resources | partial |
| Conventional React/TypeScript | runtime_only |

Implementation proceeds through complete domain support, security and runtime
settings, flow language, UI, integrations, workflows, and finally certification
per Mendix version with `mxbuild`, Studio Pro, and semantic comparison.

Unknown variants remain fail-closed: they are preserved and reported, never
silently converted or discarded.

## Enumerations in Ruby applications

`--mode ruby` exports enumeration classes under `app/enumerations/<module>/`.
`mendix_name` and each `value` accept a stable native `id:`; values accept a
`captions:` hash for every language. Declaration order is authoritative. A
rename retains identity when its ID is retained, while removing a referenced
enumeration fails closed. Incremental merges preserve native BSON fields and
unknown localization structures that are not represented by the Ruby DSL.
