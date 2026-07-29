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
- A strict 100% library line-coverage gate.

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
