# Native Ruby coverage

This is the source of truth for expansion of the Ruby → Mendix compiler. A
surface is `native` only after tests cover creation, update, removal, reopening
the MPR, and recompilation without changing native identities.

September 28, 2026 update: this is a conservative family-level matrix, not a
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
| Constants | native |
| Entity access rules | native |
| Indexes, system members, and generalization | native |
| OQL views | partial |
| Entity lifecycle | native |
| Module roles | native |
| Project roles, demo users, and password policy | native |
| Global project-security settings and access containers | native |
| Microflows, nanoflows and core pages | partial |
| Layouts, page templates, snippets, and building blocks | native |
| Menus | partial |
| Navigation and pluggable widgets | partial |
| Scheduled events | native |
| Regular expressions (Mendix/JVM text) | native |
| Published REST and JSON mappings | partial |
| Consumed REST and consumed OData | partial |
| Message definitions and derived XML mappings | partial |
| Published OData | partial |
| App/Web Services | partial |
| XSD/WSDL and other mappings | partial |
| Java and JavaScript custom actions | native |
| External connectors | partial |
| Workflows and task pages | partial |
| Settings, themes, design system and resources | partial |
| Conventional React/TypeScript | runtime_only |

Implementation proceeds through complete domain support, security and runtime
settings, flow language, UI, integrations, workflows, and finally certification
per Mendix version with `mxbuild`, Studio Pro, and semantic comparison.

Unknown variants remain fail-closed: they are preserved and reported, never
silently converted or discarded.

## Current measurable coverage

The strict suite passed 2,110 examples and measures 100.00% of
lines (37,689/37,689) and 100.00% of branches (16,310/16,310). No executable
library code was removed from the denominator to reach the gate. CI enforces
the same 100/100 floor.

Code coverage alone does not complete functional coverage: workflows and task
pages now have a typed `partial` slice; integrations and several other families
also remain `partial`. All 455 Forms properties are 455/455 in the independent
`studio_validated` gate.

## Constants

`constant` covers all five types accepted by Mendix 11: string, Boolean,
DateTime, decimal, and integer/long. Default value, documentation, export
level, excluded state, and client exposure are editable. Two MPR → Ruby → MPR
cycles retain semantics, the unit ID, and the nested type ID without opaque
BSON. The gate also exercises the exported `:date_time` spelling and
normalizes it back to the native type without changing identity.

The five-type fixture packages successfully with MxBuild 11.12.1. DateTime
uses the native `yyyy-MM-ddTHH:mm:ss` format required by the Studio Pro
validator. Private configuration overrides remain in the local sidecar and
their values are not emitted into public Ruby.

## Entity access rules

`access_rule` covers every Mendix 11 `DomainModels$AccessRule` and
`DomainModels$MemberAccess` property: module roles, create/delete,
documentation, default rights, XPath and caption, plus `None`, `ReadOnly`, and
`ReadWrite` rights for attribute and association members. Qualified inherited
member references are retained.

Two MPR → Ruby → MPR cycles retain semantics and rule/member IDs. The gate
includes two ACLs with the same role/XPath signature: the MPR DSL keeps their
explicit IDs, while Ruby-app mode uses stable private identities and emits no
UUIDs publicly. Reconciliation tests already cover authoritative creation,
editing, and removal. The complete fixture packages successfully with MxBuild
11.12.1 without opaque fallback.

## Indexes, system members, and generalization

Indexes cover all three member types that Studio Pro 11.12.1 can materialize:
normal attributes, `CreatedDate`, and `ChangedDate`, including ordering,
direction, `IncludeInOffline`, GUIDs, and member IDs. `Association`, `Owner`,
and `ChangedBy` remain in Mendix's stored enum, but `EntityIndex` itself cannot
resolve them; MXRB now rejects them before producing an invalid MPR.

All four system-member flags (`owner`, `created_date`, `changed_date`, and
`changed_by`) and qualified generalizations are editable. The gate performs a
Ruby-app export and two MPR → Ruby → MPR cycles, requires identical comparison
and stable IDs, and permits no opaque BSON fallback. Official MxBuild 11.12.1
finishes with `BUILD SUCCEEDED`. OQL views remain separately `partial`.

## Entity lifecycle

`before_commit`, `after_commit`, `before_delete`, and `after_delete` cover the
complete native `Moment` × `Type` matrix. The microflow reference,
`PassEventObject`, `RaiseErrorOnFalse`, and ID are editable; the authoritative
collection supports creation, editing, and removal without positional
matching.

The modern event field is `Type`, as defined by the 11.12.1 metamodel. Reading
and reconciliation still accept legacy `Event`, while new units no longer emit
it—preventing `Delete` from being silently interpreted as the default
`Commit`. Ruby-app and two MPR → Ruby → MPR cycles retain identical comparison
and stable IDs without opaque fallback. Official MxBuild packages the
four-event fixture with `BUILD SUCCEEDED`.

## Module roles

`module_role` covers the complete Mendix 11 `Security$ModuleRole` structure:
name, description, and identity inside a stable `Security$ModuleSecurity` unit.
The authoritative collection supports creation, editing, removal, and explicit
renaming without positional matching.

The gate exports both Ruby-app and regular DSL forms, performs two MPR → Ruby
→ MPR cycles, checks unit and role IDs, and forbids opaque fallback. Its real
project roles reference the module roles, and official MxBuild 11.12.1 packages
the fixture with `BUILD SUCCEEDED`.

## Project roles, demo users, and password policy

`user_role` covers name, description, `CheckSecurity`, GUID, module roles,
manageable roles, `ManageAllRoles`, and `ManageUsersWithoutRoles`. Demo users
cover name, entity, project-role assignments, and identity. Password policy
covers minimum length, digit, mixed case, and symbol requirements with a
stable ID.

Ruby-app redacts demo-user passwords from public source (`password: nil`) and
restores them from the private baseline, so the value does not leak during
export. The gate performs Ruby-app and two regular cycles, requires identical
comparison, stable IDs/GUIDs, and no opaque fallback. Official MxBuild 11.12.1
packages the complete fixture with `BUILD SUCCEEDED`.

## Global project-security settings and special ACLs

`check_security`, `strict_page_url_check`, `strict_mode`, `admin_user`, and the
security level are editable in both the regular and Ruby-app DSLs. The admin
password is write-only: applications may set it explicitly, exported source
never contains it, and recompilation restores it from the private baseline.
Omitted declarations preserve both the password and existing native access
containers.

`file_document_access_rule` and `image_access_rule` cover documentation,
create/delete rights, default rights, XPath/caption, members, and `System`
module roles. Ruby-app and two regular cycles retain container, rule, and
member IDs without opaque fallback. Separate global-settings and ACL fixtures
both package with `BUILD SUCCEEDED` under official MxBuild 11.12.1.

## Workflows and task pages

`workflow` authors context, name/description templates, due date, start/end,
and simple human tasks. A `SingleUserTaskActivity` references a task page whose
required `System.WorkflowUserTask` object parameter is editable through the
page DSL, together with XPath targeting, `NoEvent`, and one empty-flow outcome.
Two MPR → Ruby → MPR cycles preserve workflow semantics and every nested
workflow identity without opaque BSON, and the official MxBuild 11.12.1
packages the fixture successfully. Alternative task/targeting variants,
multi-outcome flows, timers, boundary events, subprocesses, and advanced
security remain lossless fallback, so the family stays `partial`.

## Scheduled events

`scheduled_event` covers all four concrete Mendix 11 schedules: minute, hour,
day, and week. Interval, offsets, clock time, weekdays, time zone, overlap
policy, enablement, handler, and metadata are editable. Two cycles retain the
unit and nested schedule IDs, and the four-kind fixture packages successfully
with MxBuild 11.12.1. Unknown future schedule types remain fail-closed in the
lossless fallback without reducing the versioned native claim.

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

## Published REST and JSON mappings

`spec/fixtures/published_rest/project.rb` declares a service with resources,
GET/POST operations, path parameters, microflows, and success status.
The compiler infers typed JSON structures and export mappings for entity/list
responses. Two Ruby → MPR cycles retain unit IDs, emit no `deep_structure`, and
remain semantically identical. `script/frontend_acceptance` also accepted the
source and rebuilt projects with MxBuild 11.12.1, zero errors, and
`frontend_ready: true`.

The family remains `partial`: only recognized shapes use the semantic DSL;
unrepresented operations, authentication, or mapping variants keep the
lossless fallback.

## Consumed REST and consumed OData

`spec/fixtures/consumed_services/project.rb` combines a bodyless REST GET with
URL parameters, ordered headers, timeout, and HTTP response handling with a
consumed OData service backed by valid CSDL v4 and a constant-based service
URL. Two Ruby → MPR cycles retain semantics and unit IDs without
`native_fragment`, `deep_structure`, or opaque BSON in the certified sources.
Official MxBuild 11.12.1 accepts both source and rebuilt projects with zero
errors, no structural differences, and `frontend_ready: true`.

Bodyless calls use the empty `CustomRequestHandling` shape observed in real
projects. The DSL rejects a mapping without its variable, a variable without
its mapping, and mixing a custom body with an export mapping. The family stays
`partial`: form-data, authentication/proxy variants, metadata references, and
validated OData entities retain the lossless fallback when unrecognized.

## Message definitions and derived XML mappings

`spec/fixtures/message_xml/project.rb` declares an entity and attributes
exposed through a `MessageDefinitionCollection`, import/export mappings with
`XmlPath`, and two microflows that import and export XML. Two Ruby → MPR cycles
retain semantics and unit IDs without `native_document`, `deep_structure`,
`native_fragment`, or opaque BSON in the certified sources. Official MxBuild
11.12.1 accepts source and rebuilt projects with zero errors, no structural
differences, and `frontend_ready: true`.

Message-definition mappings do not enable schema validation because MxBuild
reserves it for XSD-based mappings. The family remains `partial`: nested trees,
associations, converters, XSD/WSDL, and other variants retain the lossless
fallback until they receive dedicated evidence.

## App Services and Web Services

Consumed App Services now expose location, timeout, App Store metadata,
actions, parameters, and return values through `consumed_app_service`.
Published SOAP services expose versions, namespaces, authentication,
operations, scalar parameters, and microflow references through
`published_web_service`. The gate performs two Ruby → MPR cycles and requires
identical comparison and stable unit IDs; the legacy `ConnectorKitDemo` corpus
also exports recognized shapes through the semantic DSL.

The family remains `partial`: embedded MSD contracts are preserved losslessly,
while structured SOAP entities, child members, and future variants retain the
fail-closed fallback until they receive a dedicated typed model.

## XSD and associated mappings

`xml_schema` declares XSD files with paths, contents, target namespaces, and
localized formats. Import/export mappings can reference the schema and root
element through the existing DSL. Two Ruby → MPR cycles retain IDs and semantic
equivalence; official MxBuild 11.12.1 packages the complete fixture, including
the import mapping, with zero errors.

The implementation also covers `imported_web_service` with raw WSDL contents,
embedded schemas, URL, target namespace, and import/MTOM flags. It uses the
legacy physical names `ImportedServiceImpl`, `WsdlDescriptionImpl`,
`WsdlEntryImpl`, `SchemaContentss`, and `XmlSchemaContents`, which differ from
the public Model SDK names. The family stays `partial` while parsed WSDL
services and operations, complex mapping trees, and other variants still use
the lossless fallback.

## Java and JavaScript custom actions and external connectors

`java_action` materializes the native signature, parameters, generic types,
return type, and visual metadata. The `mxrb java-action new` scaffold also
creates the `UserAction` class under `javasource/<module>/actions`; exports copy
the sources and two Ruby → MPR cycles retain content, semantics, and IDs. The
complete fixture compiles and packages with MxBuild 11.12.1.

`javascript_action` provides the same client-side contract, including platform,
parameters, and return type. `mxrb javascript-action new` creates the source
under `javascriptsource/<module>/actions`; two cycles retain the file and unit,
and the certified Web package also completes with MxBuild 11.12.1.

Marketplace connectors remain external dependencies: MXRB audits verified
GUIDs, public surface, and provenance, and installs only through an
authenticated official adapter. Protected modules are not presented as
editable, and unresolved package requests fail closed.

## Published OData

`spec/fixtures/published_odata/project.rb` declares a read-only OData 4 service
with an allowed role, Basic authentication, an entity type, ID, attributes,
and a paged entity set with query options. Two Ruby → MPR cycles retain
semantics and unit IDs without `native_document`, `deep_structure`,
`native_fragment`, or opaque BSON in the certified source. Official MxBuild
11.12.1 accepts source and rebuilt projects with zero errors, no structural
differences, and `frontend_ready: true`.

The service location ends in `/` as required by MxBuild rule CE6552. The
family remains `partial`: write modes, published microflows, enumerations,
associations, GraphQL, and other variants retain the lossless fallback until
they receive dedicated evidence.

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
