# MXRB architectural standard

[Português](../pt-BR/architectural-standard.md) · **English** · [Deutsch](../de-DE/architectural-standard.md)

## 1. Central principle

Ruby is the canonical representation of architecture. Mendix remains the
execution platform and native model; MXRB must preserve compatibility without
forcing platform internals into application code.

## 2. Complete structure

Applications are split into app-level security/navigation and modules with
`domain`, `application`, `presentation`, `infrastructure` and module security.
Large presentation areas use vertical feature slices.

## 3. Flow mapping

- Domain rules express entity-level invariants.
- Application microflows implement use cases, queries, validations and jobs.
- Presentation nanoflows implement client interaction.
- Infrastructure flows implement services, adapters and integrations.
- Events and callbacks point to these responsibilities instead of defining a
  second architecture.
- `uses_repository`, `calls`, lifecycle and data-source declarations feed the
  semantic dependency graph.

A microflow is classified by responsibility, not by being a microflow.

## 4. Allowed dependencies

`presentation` and `infrastructure` may depend on `application`; application
may depend on domain. Domain does not depend on outer layers. Cross-module
access should use a declared public API.

## 4.1 Queries, repositories and Mendix persistence

Direct Mendix retrieval is appropriate for ordinary CRUD. A repository is
introduced when it represents a meaningful port: external storage, a complex
query contract, test isolation or an architectural boundary.

## 5. Public module API

Artifacts intended for other modules are explicitly public. Internal
microflows and entities are not treated as contracts merely because their
qualified names are discoverable.

## 6. Security

App security owns user roles and project-wide policy. Module security owns
module roles. Pages, microflows and nanoflows declare allowed module roles.
Unknown native security settings are preserved until they have a typed Ruby
representation.

## 7. Navigation

Navigation is application-level. Menus preserve translations, nested items and
native actions through concise DSL plus authoritative deep structures.

## 8. Design system

Semantic Ruby tokens describe intent; Mendix resources implement it. Native
themes, images and design properties remain preserved even when no concise DSL
exists yet.

## 9. Design patterns

Use-case, query, adapter, strategy and policy objects are encouraged when they
clarify a boundary. Avoid ceremonial layers around native Mendix behavior.

## 10. Naming

Mendix-qualified names are canonical. Ruby files use `snake_case`; classes and
symbols may adapt names without changing Mendix identity.

## 11. Automatable quality rules

MXRB can enforce missing references, forbidden dependencies, cycles, access
boundaries, naming policy, unreferenced-artifact thresholds and custom Ruby
checks. Official `mx check` and MxBuild remain final platform gates.

## 12. Current support boundary

Typed domain, flow, page, menu, security and semantic surfaces are editable.
Other units are retained in the native baseline. Preservation is not data
loss; it is the compatibility mechanism until a typed Ruby API is added.
