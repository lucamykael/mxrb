# Native Ruby coverage

This is the source of truth for expansion of the Ruby → Mendix compiler. A
surface is `native` only after tests cover creation, update, removal, reopening
the MPR, and recompilation without changing native identities.

September 13, 2026 update: this is a conservative family-level matrix, not a
completion percentage. Domain, security and scheduling now have incremental
authoring paths; unrepresented variants remain preserved. Verified contracts
and limitations are recorded in the
[Ruby round-trip review (Portuguese)](../reviews/ruby-code-review-2026-09-05.pt-BR.md).

States are `native`, `partial`, `preserved_native`, and `runtime_only`.

| Surface | State |
|---|---|
| Entities, non-persistent DTOs and attributes | native |
| Local and cross-module associations | native |
| Enumeration definitions | native |
| Constants and entity access rules | partial |
| Indexes, system members, generalization and OQL views | partial |
| Entity lifecycle | partial |
| Module roles and project security | partial |
| Microflows, nanoflows and core pages | partial |
| Layouts, snippets, building blocks and menus | preserved_native |
| Navigation and pluggable widgets | partial |
| Scheduled events | partial |
| Regular expressions (Mendix/JVM text) | native |
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

## Current measurable deficit

The September 13 strict suite passed 1,805 examples but still measures 96.18%
of lines (35,115/36,511) and 89.22% of branches (14,119/15,825). Reaching the
100/100 gate therefore requires another 1,396 executable lines and 1,706
branches. The largest gaps are in `ruby_app/exporter.rb`, `exporter.rb`,
`writer.rb`, `dsl/builder.rb`, and `writer/page_overlay.rb`; none were removed
from the denominator. CI remains at 96/89 until real tests close the balance.

Code coverage alone does not complete functional coverage: layouts, snippets,
building blocks, menus, integrations, workflows, and task pages remain
`preserved_native`, several families remain `partial`, and all 455 Forms
properties are still 0/455 in the independent `studio_validated` gate.

## Core Forms properties

`script/forms_core_project_gate` creates a Mendix 11.12.1 MPR with one isolated
occurrence of every inherited property across the 41 concrete core widgets,
exports it as readable Ruby, rebuilds it, and reopens the typed MPR. The gate
certifies 455/455 properties as `imported` and `compiled`, in addition to the
455/455 representation, source-emission, storage-transcoding, and synthetic
round-trip evidence. `studio_validated` remains 0/455 until independent
MxBuild/Studio Pro evidence exists in semantically valid widget contexts; a
structural round trip never implies that phase.

## Enumerations in Ruby applications

`--mode ruby` exports enumeration classes under `app/enumerations/<module>/`.
Generated declarations resolve native IDs through the private project baseline.
Use a `value` block with `translation 'en_US', 'Ready'` for localized captions.
The legacy `id:` and `captions:` options remain accepted. Rename a value with
`value 'New', renamed_from: 'Old'`; `remove_value 'Old'` disambiguates removal
followed by insertion. Ambiguous changes fail rather than matching by position.
Declaration order is authoritative, while removing a referenced enumeration
fails closed. Incremental merges preserve native BSON fields and unknown
localization structures that are not represented by the Ruby DSL.
