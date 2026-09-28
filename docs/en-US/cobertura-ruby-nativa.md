# Native Ruby coverage

This is the source of truth for expansion of the Ruby → Mendix compiler. A
surface is `native` only after tests cover creation, update, removal, reopening
the MPR, and recompilation without changing native identities.

September 27, 2026 update: this is a conservative family-level matrix, not a
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
| Layouts, page templates, snippets, and building blocks | native |
| Menus | partial |
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

## Current measurable coverage

The strict suite passed 2,080 examples and measures 100.00% of
lines (37,076/37,076) and 100.00% of branches (16,078/16,078). No executable
library code was removed from the denominator to reach the gate. CI enforces
the same 100/100 floor.

Code coverage alone does not complete functional coverage: integrations,
workflows, and task pages remain `preserved_native`; menus and several other
families remain `partial`. All 455 Forms properties are 455/455 in the
independent `studio_validated` gate.

## Reusable presentation documents

`script/presentation_documents_gate` authors layouts, page templates, snippets,
and building blocks through the typed Forms DSL, exports readable Ruby, and
recompiles the MPR for two cycles. It requires structural validity, stable
document semantics, and stable unit and nested-node IDs. With `--mxbuild`, the
official MxBuild 11.12.1 packages the final fixture with exit status zero and
zero problems.

Supported menu documents are authoritative too: localized captions, page and
microflow targets, glyph icons, recursive items, and document/item removal
round-trip through readable Ruby with stable compatible identities. Unknown
actions or icons fall back to lossless `deep_structure`, so the family remains
`partial`. The menu fixture passes `script/frontend_acceptance` through both
the source and rebuilt MPR with official MxBuild 11.12.1, zero errors, and no
structural differences.

Navigation profiles expose modern and legacy application titles, enabled and
offline state, role homes, login title/location, not-found targets, and
partial-sync behavior. Updating supported settings retains native and nested
identities. Unrepresented PWA and offline configuration structures stay opaque
and unchanged, so navigation remains `partial`.

## Core Forms properties

`script/forms_core_project_gate` creates a Mendix 11.12.1 MPR with one isolated
occurrence of every inherited property across the 41 concrete core widgets,
exports it as readable Ruby, rebuilds it, and reopens the typed MPR. The gate
certifies 455/455 properties as `imported` and `compiled`, in addition to the
455/455 representation, source-emission, storage-transcoding, and synthetic
round-trip evidence. A second MPR places complete witnesses in layout,
template, entity, file, and image contexts. Official MxBuild 11.12.1 packages
it with no problems, while typed inspection of that accepted artifact certifies
`studio_validated` at 455/455. The legacy `TemplatePlaceholder` is loaded from
an explicitly excluded template because Studio itself rejects it in deployable
documents.

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
