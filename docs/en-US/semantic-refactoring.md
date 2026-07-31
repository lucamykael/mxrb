# Semantic refactoring

[Português](../pt-BR/semantic-refactoring.md) · **English** · [Deutsch](../de-DE/semantic-refactoring.md)

MXRB renames, removes, moves, extracts and inlines artifacts directly in
Ruby — no Studio Pro, no MDL. Every operation follows the same
plan / preview / `apply!` pattern described in
[architectural patterns](architectural-patterns.md): build a plan, inspect
its changes, then write inside a transaction.

All examples assume a writable project:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  # plans below
end
```

The CLI equivalents preview by default and require `--apply` to write.

## Finding artifacts and references first

Refactoring decisions start from the semantic index:

```ruby
project.find_artifact("Sales.Order", kind: :entity)
project.search_artifacts("order", kind: :microflow)
project.semantic_search_artifacts("create a customer order", limit: 5)
project.references_to("Sales.Order")
project.references_from("Sales.Order_Overview")
project.callers_of("Sales.Recalculate")
project.callees_of("Sales.Checkout")
project.impact_of("Sales.Order").artifacts
```

`impact_of` is transitive by default; pass `transitive: false` for direct
dependents only. CLI: `mxrb find`, `mxrb refs`, `mxrb callers`,
`mxrb callees`, `mxrb impact`.

Semantic search always has a deterministic Ruby backend. Installing the
optional `sqlite-vec` gem enables a fingerprinted KNN cache inside writable
MPRs; read-only projects and platforms without the native extension keep the
same API and rank in memory. The first accelerated call populates the vector
table before recording its backend, dimension and model fingerprint, so an
empty or stale index is never treated as ready.
Use `mxrb find app.mpr "customer order" --semantic` for the legacy adapter.
The dedicated command also exposes the backend, result limit, and cosine
distance:

```sh
bundle exec mxrb search "payment" App.mpr
bundle exec mxrb search "create order" App.mpr --backend onnx --limit 5
```

Tabular output contains rank, distance, qualified name, and kind; `--json`
provides the same fields for automation.

For local ONNX development, enable the optional dependency group with
`BUNDLE_WITH=onnx bundle install`. `backend: :onnx` and the automatic backend
then use Informers' documented `embedding` pipeline with
`sentence-transformers/all-MiniLM-L6-v2`. CI sets `MXRB_ONNX=1` in its
dedicated job and runs a real 384-dimensional model smoke test; ordinary test
and gem installations do not download the model.

The native sqlite-vec smoke test uses its own supported-platform dependency
file: `BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle install`, followed by
`MXRB_SQLITE_VEC=1 BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle exec rspec
spec/semantic_search_spec.rb`. This keeps unsupported architectures out of the
main lockfile while CI still exercises the actual extension.

## Rename

```ruby
plan = project.plan_rename("Sales.Order", to: "Invoice")
plan.changes.each { puts "#{_1.path.join(".")}: #{_1.before} -> #{_1.after}" }
plan.apply!
# or in one step: project.rename!("Sales.Order", to: "Invoice")
```

The plan rewrites the declaration and deep references across the model,
including Mendix member paths such as `Sales.Order/Number`. It validates name
rules, qualification depth, collisions and container legality before writing.

```sh
bundle exec mxrb rename app.mpr Sales.Order Invoice --apply
```

## Remove

```ruby
plan = project.plan_remove("Sales.UnusedFlow")
plan.apply! if plan.safe?
```

Removal is blocked while incoming references or child units exist, and a plan
cannot be applied twice. Embedded domain-model elements (entity, attribute,
association) are not standalone units — use the typed domain mutations below
instead.

```sh
bundle exec mxrb remove app.mpr Sales.UnusedFlow --apply
```

## Move

```ruby
plan = project.plan_move("Sales.Process", to: "Sales.Automation")
plan.apply!
```

A same-module move changes the unit's container (module folder) while
preserving its qualified name, so references stay intact. Folder cycles,
embedded elements and non-container targets are rejected. Cross-module moves
compose the move with a rename so calls, security, pages and contracts are
updated atomically; both directions are validated on MPR v1 and v2.

```sh
bundle exec mxrb move app.mpr Sales.Process Sales.Automation --apply
```

## Extract a submicroflow

`plan_extract` lifts a subgraph of activities into a new submicroflow and
patches the source with a call to it:

```ruby
plan = project.plan_extract("Sales.CreateOrder",
                            as: "Sales.Validate",
                            object_ids: [first_activity_id, second_activity_id])
plan.apply!
```

Extraction requires the source to be a microflow in the same module, a free
target name, existing activity IDs that are not start/end events, and exactly
one entry point and one exit point in the selected subgraph.

## Inline a called microflow

`plan_inline` is the inverse: it replaces a `call_microflow` activity with
the callee's own activities, remapping object UUIDs so nothing collides with
the caller:

```ruby
plan = project.plan_inline("Sales.CreateOrder", calling: "Sales.Validate")
plan.apply!
```

## Domain-model mutation

Entities and attributes are embedded in the domain model, so they have typed
mutations of their own:

```ruby
project.plan_add_entity("Sales", name: "Invoice").apply!
project.plan_add_attribute("Sales.Invoice", name: "Number", type: :string,
                           required: true).apply!
project.plan_change_attribute("Sales.Invoice.Number", length: 40).apply!
project.plan_remove_attribute("Sales.Invoice.Number").apply!
project.plan_remove_entity("Sales.Invoice").apply!
```

Each has a bang convenience form (`add_entity!`, `add_attribute!`, ...).

## Batch plans

Several plans can be previewed and applied as one unit:

```ruby
batch = project.batch_plan([
  project.plan_rename("Sales.Order", to: "Invoice"),
  project.plan_move("Sales.Process", to: "Sales.Automation")
])
batch.apply!
```

## Static analysis alongside refactoring

`project.analyze` (aliased as `lint`) reports missing internal references,
external contracts, call cycles, unreferenced artifacts and module coupling,
and accepts custom Ruby rules:

```ruby
report = project.analyze(rules: [my_rule])
report.errors.each { warn _1.message }
```

CLI: `mxrb lint app.mpr` and `mxrb report app.mpr`.

## Structural version migration

For projects generated by MXRB (which store their architecture definition in
the MPR), `migrate_to!` re-runs the writer with a different Mendix version so
every version-specific BSON structure is regenerated correctly. It is
idempotent and also aliased as `upgrade_to!` / `downgrade_to!`:

```ruby
project.migrate_to!("11.12.1")
```
