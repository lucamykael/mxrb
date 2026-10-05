# MXRB: Ruby above all

## Editable collection menu icons and JavaScript callbacks

The eight-project audit found 125 auxiliary BSON files. Of these, 112 already
had typed `Mxrb::Forms` declarations and no remaining reference to the auxiliary
file. Counting BSON files as uneditable documents therefore overstated the gap.
The 13 generic cases were 12 collection-icon menus and the signature of
`NativeMobileActions.RegisterDeepLink`.

Menus now emit `icon: { collection: "Module.Collection.Icon" }`. Adding, changing,
switching to glyphs and removing icons preserves item identities. Native defaults
and BSON collection markers survive reconstruction without reviving removed
items. JavaScript action parameters support `kind: :nanoflow` with stable IDs.
The original and rebuilt SLA menus and action signature compare identically.

The Ruby frontend exports local fonts by hash and editable icon resources. The
Chromium scenario `editable_menu_icons_flow.json` checks display and navigation
with MPR access forbidden. Windows certification includes the menu and callback
contract in source and roundtrip variants; it does not execute the callback or
certify native deep-link integration.

Fresh exports of all eight projects contain no generic `native_document` or
opaque menus. The 112 auxiliary files remain alongside their typed Ruby
representations. This does not certify every runtime, mobile layout or custom
Java/JavaScript integration. See the
[editability evidence](../evidence/editability-2026-10-05.json).


## Charts with bound data

The frontend queries authorized entity sources with XPath and context, sorts
records and refreshes charts after changes. Line, area, column, horizontal bar,
bubble, time-series, pie and heatmap charts use actual values; CustomChart accepts
explicit bar/scatter JSON series. An accessible table preserves values, common
categories align across series and nulls do not become zeros. Source failures
produce an error instead of a decorative graph.

The `marketplace_chart_project.rb` fixture in `spec/fixtures/frontend_browser`
uses `MXRB_OUTPUT_PATH` and `MXRB_CHARTS_PACKAGE`. Certification uses Charts 6.2.1;
the locally available 4.2.4 package failed React client bundling in Studio 11.12.1.
The third-party package is not distributed by this repository.

The oracle also exposed missing optional templates. The generator initializes
empty text for active sources, preserves inactive sources and explicit clearing,
and exports nested series names. Browser tests run the Ruby version with MPR
opening forbidden.

The native scope checks values and refresh behavior for line, bar and pie charts.
It does not establish complete visual equivalence, parameterized templates,
point events, themes, custom layouts or every Plotly option. Aggregations, dynamic
series and bar modes other than `group` still require an adapter; the renderer
rejects these configurations instead of displaying incorrect data.
See the [chart evidence](../evidence/chart-data-2026-10-05.json).
Windows CI repeats this scenario with the package pinned by commit and checksum.

## Additional catalog, rule and widget revision

The catalog for `runtime_model: ruby` applications now reconciles removed and
renamed loaded declarations while preserving the export manifest. Persistent
renames use `renamed_from`; removing a class does not authorize dropping its
table. Legacy mode continues to retain undeclared metadata.

Rules export as `flow :rule` services with their export level preserved.
Decisions call the current Ruby implementation, including after edits, and
annotations can reference those decisions. The Writer emits textual captions
and accepts immutable declaration snapshots.

The frontend exposes `registerMarketplaceWidget` for exact widget identity
adapters. Images, sliders, ranges, progress, ratings, colors and enumeration
buttons use bound properties and data, respecting inherited editing policy.
Scanners, Java/JS actions and other native variants still require specific
implementation and certification; the chart scope is described above.

Edited VetClinic passed authenticated Chromium creation and persisted reads at
1280×900 and 390×900 with MPR opening forbidden. Preparation lives in
`spec/fixtures/frontend_browser/prepare_vetclinic_edited.rb`; the proof server
is `serve_without_mpr.rb` in the same directory. Both use a fresh export and
leave original projects intact.


An additional run passed ten builds: contracts, presentation, core widgets,
validation and compatibility, each as source and Ruby round-trip. Ten rule and
string probes passed in each compatibility package's Runtime. The oracle
revealed and helped correct non-text rule decision captions and URL encoding
(space `%20`, asterisk `%2A`, tilde `~`). See the
[compatibility evidence](../evidence/compatibility-2026-10-05.json).


String search and slicing now count UTF-16 units: `find` honors its start
position, `findLast` locates the final occurrence, and `substring` rejects
invalid ranges. Complete surrogate pairs are preserved; invalid Unicode
strings are explicitly rejected. Certified native cases are listed in the
[string evidence](../evidence/string-parity-2026-10-05.json).


## October 5, 2026 update

The runtime catalog discovers new models, DTOs, pages, enumerations and services
from loaded Ruby files without hand-editing the manifest. Applications marked
`runtime_model: ruby` run without opening an MPR; legacy exports must be exported
again to adopt this contract. Deleting or renaming legacy catalog entries still
requires explicit reconciliation.

UI policy now combines module roles and visibility/editability expressions with
inherited Data View restrictions. Unknown roles cannot grant access. Server
permissions remain authoritative. XPath includes string/date functions, period
keywords and session time zones, with calendar month/year boundaries and DST
tests. This does not establish universal database or native-function parity.

Persistent and transient callbacks reach subtypes. Inherited validation rules
now enforce required values, uniqueness across subtype tables, equality,
inclusive ranges and UTF-16 length at commits with events. Rejected transactions
roll back and HTTP returns structured 422 feedback. JVM regular expressions need
an explicit `regular_expression` adapter; unsupported rules fail explicitly.
A 21-case matrix matched native Runtime: see the
[parity evidence](../evidence/validation-parity-2026-10-05.json). Equality uses
`Value` in native storage. Date-only bounds were certified; Runtime 11.12.1
rejected a bound with time that MxBuild accepted, so that variant is not certified.

Edited VetClinic Ruby sources passed service creation, a new model column,
page projection, persistence after reopening, rollback and deletion with MPR
access forbidden ([evidence](../evidence/vetclinic-ruby-2026-10-05.json)). Native
lifecycle callbacks now share the API transaction.

[Windows certification](windows-studio-pro.md) passed six local native builds
and official Runtime CRUD. VetClinic passed themed rendering and native client
API CRUD. The [report](../evidence/native-2026-10-05.json) distinguishes this from
complete form, theme, external-widget, custom Java/JS and mobile-layout parity.
The weekly workflow adds native builds and headless runtime acceptance.

[Português](../pt-BR/ruby-first-roadmap.md) · **English** · [Deutsch](../de-DE/ruby-first-roadmap.md)

## Architectural principle

Ruby is MXRB's only public language.

- Mendix models are read, created, changed and analyzed through Ruby APIs and DSLs.
- The CLI is a thin layer over those APIs.
- MXRB will not introduce MDL or a competing parser/language.
- Structures without a concise high-level API remain losslessly preserved and
  editable through generated `native_unit` Ruby hashes.
- Studio Pro and MxBuild are important external validators, not dependencies of
  the Ruby core.

## Available capabilities

- Deep MPR v1/v2 reading and writing.
- Export to editable Ruby projects.
- Generation, integrity validation and structural comparison.
- Semantic indexing of modules, entities, members and documents.
- References, callers, callees and transitive impact queries.
- Safe model-wide rename with preview.
- Static analysis of cycles, missing targets and module coupling.
- Typed semantic diff.
- Search, description and structural tree navigation.
- Executable Ruby model evaluations with severity and scores.
- Functional microflow tests without JUnit.
- Local or Docker execution of `mx check`, portable MxBuild and Runtime.
- A native coverage gate enforcing 100% lines and 100% branches in CI and
  locally.

## Semantic API

```ruby
Mxrb.open("app.mpr") do |project|
  order = project.find_artifact("Sales.Order")
  refs = project.references_to(order)
  callers = project.callers_of("Sales.Recalculate")
  callees = project.callees_of("Sales.Checkout")
  impact = project.impact_of("Sales.Order")
end
```

Results are immutable Ruby objects: `Mxrb::Semantic::Artifact`,
`Mxrb::Semantic::Reference` and `Mxrb::Semantic::Impact`.

Writable projects persist a fingerprinted semantic-index cache in the MPR.
Read-only opens may reuse that cache but never modify the project.
Use `mxrb cache status`, `warm` and `clear` for metrics and maintenance; writes
use an upsert before stale-entry cleanup so readers never observe an empty
replacement window.

Exact native Mendix 5 validation remains dependent on Windows/Studio Pro. It
is documented as a remote legacy limitation and is not a current delivery
gate.

Navigation profiles now read and write native Mendix navigation documents,
including role homes and recursive menus. Theme and source assets round-trip
through a checksum manifest; design-system tokens support inventory, lint,
contrast metrics and preview-first literal migration.

## Safe rename

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Order", to: "Invoice")
  plan.changes.each { puts _1.inspect }
  plan.apply!
end
```

The CLI previews by default; `--apply` is required to write.

## Safe removal

Standalone units such as microflows and pages can be inspected before removal:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_remove("Sales.UnusedFlow")
  plan.apply! if plan.safe?
end
```

The plan is blocked while incoming references or child units exist. Embedded
domain-model elements require their typed domain-model mutation instead. The
CLI follows the same rule: `mxrb remove app.mpr Sales.UnusedFlow` previews and
`--apply` writes only a safe plan.

## Safe same-module move

Standalone units can move to a module or folder without changing their
qualified name or references:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_move("Sales.Process", to: "Sales.Automation")
  plan.apply!
end
```

The plan preserves the native containment type and blocks embedded
domain-model elements, non-container targets, folder cycles and cross-module
moves. `mxrb move app.mpr Sales.Process Sales.Automation` previews the exact
container IDs; `--apply` performs the transaction.

## Static analysis

```ruby
report = Mxrb.open("app.mpr", &:analyze)
report.errors.each { warn _1.message }
report.call_cycles.each { puts _1.artifacts.map(&:qualified_name) }
```

Absent targets in an existing module are errors. External contracts are
warnings, and `System.*` references are recognized as platform references.

## Typed diff and navigation

```ruby
result = Mxrb.diff("before.mpr", "after.mpr")
result.added.each { puts _1.path }
project.search_artifacts("checkout", kind: :microflow)
project.describe_artifact("Sales.Checkout")
```

CLI equivalents include `diff`, `find`, `describe` and `tree`.

## Model evaluations

```ruby
result = Mxrb.open("app.mpr") do |project|
  project.evaluate do
    artifact "Sales.Order", kind: :entity
    no_call_cycles
    no_missing_internal_references
    maximum_unreferenced 20, severity: :warning
  end
end
```

Evaluation files are ordinary Ruby and run with
`mxrb evaluate app.mpr evaluation.rb`.

## Official Mendix Marketplace

This command family remains separate from `mxrb module`. It integrates the
documented Marketplace Content API for authenticated search, metadata,
compatible versions, direct download, private company content, and security
auditing. GitHub releases and local MPK import remain fallback routes.

Local MPKs are imported directly into the target MPR through Ruby/SQLite/BSON,
including the complete unit tree and declared assets, without Mendix tools.
The PAT requires `mx:marketplace-content:read`. Official downloads are selected
against the target MPR version, vulnerable releases are denied by default, and
Content/Version IDs plus security metadata are written to the lockfile.
Authenticated Kafka acceptance and transactional lifecycle are now delivered.
`marketplace update` and `marketplace remove` preview by default, preserve
externally referenced IDs, reject changed assets, and snapshot MPR,
`mprcontents`, cache, lock, and assets before explicit `--apply`. Remaining
authenticated work is also delivered: `marketplace dependencies` recursively
resolves official packages from references in the embedded MPR, verifies each
downloaded MPK's actual module identity, recognizes host-owned modules, applies
leaf-first, and rolls back atomically. Kafka package graphs passed authenticated
10.24 and 11.12 acceptance, and imported modules now export to Ruby and rebuild
with asset checksums and source/rebuild diagnostics preserved.

The authenticated matrix now includes DataWidgets 3.11.3 (Content ID 116540,
Version ID `e7b6d703-8e47-42f4-bb92-934e3601e71b`) and the independent official
Combo box Widget/clientModule component 219304, version 2.9.0, Version ID
`dce845f4-d051-4161-847c-016c01703caa`. Combo installation backs up and
replaces the 2.6.x asset previously owned by Atlas Core (Content ID 117187).
Ruby round trips preserve Marketplace lock/cache/original provenance, and
`script/frontend_acceptance` fails on model, asset, checksum, or provenance
drift. Native renderer coverage for the accepted 10.24 and 11.12 fixtures has
zero source and rebuilt preflight findings.

The migration interface is delivered as `mxrb frontend migrate FILE.mpr`: it
previews by default and writes a safe transactional plan only with `--apply`.
That migration track is complete across the supported frontend matrix. The
optional external MxBuild oracle returns zero errors for source and rebuild on
10.24 and 11.12; `mx check` also preserves byte-identical observable package
diagnostics across each round trip. MXRB remains independent: `mx` and MxBuild
are validation oracles only, never generators, mutators, or runtime dependencies.
