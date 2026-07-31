# Mendix project architecture in MXRB

[Português](../pt-BR/architecture.md) · **English** · [Deutsch](../de-DE/architecture.md)

MXRB represents a Mendix project as editable Ruby while preserving the native
model required for a safe round trip. Ruby is the source-facing language; no
parallel MDL-like syntax is introduced.

## Mendix compatibility principles

- Mendix qualified names remain canonical inside the model.
- Existing native units are preserved when no typed Ruby abstraction exists.
- A typed edit replaces only the structure that Ruby explicitly owns.
- MPR v1 contents stay in SQLite; MPR v2 contents stay in `mprcontents/`.
- UUIDs, BSON GUIDs, containment and content hashes are handled by MXRB.
- Official `mx`, MxBuild and Runtime are compatibility gates, not core APIs.

## Canonical structure

```text
project.rb
app/
  security/
  navigation/
modules/
  Sales/
    module.rb
    domain/
      model.rb
      entities/
    application/
      use_cases/
      queries/
    presentation/
      pages/
      client_actions/
    infrastructure/
      integrations/
      services/
    security/
```

The structure is deliberately regular. Exported files can be reviewed in Git,
edited in Ruby and regenerated without flattening Mendix folders or dropping
unknown documents.

## Clean Architecture mapping

### `domain/`

Contains entities, attributes, associations, value rules and domain events.
It must not depend on presentation or infrastructure details.

```ruby
entity :Order do
  string :Number, documentation: "Stable order number"
  decimal :Total, default: 0
  association "Sales.Customer", name: "Order_Customer"
end
```

Association cardinality follows the Mendix type/owner model:

```ruby
# 1:N (default): Reference + Default
association "Sales.Customer", name: "Order_Customer"

# 1:1: Reference + Both
association "Sales.Profile", name: "Customer_Profile", owner: :Both

# N:N: ReferenceSet + Default
association "Sales.Tag", name: "Order_Tags", type: :ReferenceSet
```

### `application/`

Contains use cases, queries, validations and jobs. A microflow is not
automatically a service: its role is determined by its responsibility.

```ruby
microflow :CreateOrder do
  return_type :Order
  create_object "Sales.Order", as: :order
  return_value :order
end
```

### `presentation/`

Contains pages, UI entry points and client-side nanoflows. Feature-oriented
folders are preferred when a module has several independent user journeys.

### `infrastructure/`

Contains integrations, published/consumed services, adapters and technical
implementation details. Repository abstractions are used only at real
boundaries; ordinary Mendix CRUD does not require ceremonial wrappers.

## Dependency rule

Dependencies point inward:

```text
presentation ─┐
              ├─> application ─> domain
infrastructure┘
```

The semantic graph validates missing targets, cycles, cross-module relations
and forbidden architectural dependencies.

## Root file

`project.rb` loads the application-level configuration, native baseline and
module aggregators. It should contain orchestration, not business behavior.

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"
  native_units File.join(__dir__, ".mxrb", "native_units.json")
  load File.join(__dir__, "modules", "Sales", "module.rb")
end
```

## Ruby-to-Mendix flow

1. Ruby definitions are evaluated.
2. The writer creates or opens the target MPR.
3. Native units are restored first.
4. Typed overlays are matched by stable Mendix names.
5. Changed flow/page structures are regenerated.
6. Hashes and v1/v2 storage are updated.
7. `mxrb validate`, `mx check` and MxBuild can act as successive gates.

## Mendix-to-Ruby flow

1. MXRB indexes all project units.
2. Typed modules, entities, pages, menus and flows are exported.
3. Deep page/flow structures remain editable Ruby.
4. Unknown units are written to `.mxrb/native_units.json`.
5. Canonical fingerprints permit exact reuse of unchanged native graphs.

## Safe round-trip strategy

### Preserving update

Use the exported native baseline when editing an existing project. This mode
keeps structures outside the currently typed surface without treating them as
discardable opaque data.

### Reconstruction

For a new project, MXRB creates the SQLite schema, root unit, module tree and
v2 `.mxunit` files when required. Exact official validation still depends on
the matching Mendix toolchain.

## Naming conventions

- Mendix names are preserved exactly.
- Ruby filenames use `snake_case`.
- Ruby symbols may adapt names for readability.
- Comparisons use Mendix-qualified identity, never filenames.
- Renames are previewed across the semantic graph before being applied.

## Source of truth

Ruby is authoritative for explicitly declared typed structures. The native
manifest is authoritative for preserved structures outside that declaration.
When a deep Ruby structure is edited, its fingerprint changes and the writer
regenerates that structure rather than silently restoring the old native one.
