# MXRB: Ruby above all

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
- A strict 100% library line-and-branch coverage gate.

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
