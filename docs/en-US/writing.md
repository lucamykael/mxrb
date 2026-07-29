# Writing projects

[Português](../pt-BR/writing.md) · **English** · [Deutsch](../de-DE/writing.md)

For the complete module, layer and round-trip structure, see
[project architecture](architecture.md).

`mxrb generate` evaluates a Ruby definition and creates or updates the target
MPR. Existing modules, entities, attributes, associations, pages and
microflows are matched by name, so applying the same definition repeatedly
does not duplicate them.

```ruby
# shop.rb
Mxrb.define("Shop.mpr") do
  mendix_version "10.17.0"

  self.module :Sales do
    entity :Customer do
      string :Name, required: true, length: 200
    end

    entity :Order do
      decimal :Total, default: 0
      association :Customer
    end

    page :OrderList do
      title "Orders"
      layout "Atlas_Default"
      allowed_roles "Sales.User"
    end

    microflow :CreateOrder do
      parameter :Order, type: :Order
      return_type :Order
      allowed_roles "Sales.User"
    end
  end
end
```

Apply it using the path in the definition:

```sh
bundle exec mxrb generate shop.rb
```

Or override the output path:

```sh
bundle exec mxrb generate shop.rb output/Shop.mpr
```

## Integrity validation

Run the internal integrity check after generation or round-trip work:

```sh
bundle exec mxrb validate path/to/App.mpr
```

For MPR v1, the validator reads unit contents directly from the SQLite
`Unit.Contents` column and checks the unit tree, content hashes, and
`$ID`/`$Type` identity. For MPR v2, it performs the same checks against the
external `.mxunit` payloads in `mprcontents/`.

Compare two MPRs structurally without external tooling:

```sh
bundle exec mxrb compare original.mpr rebuilt.mpr
```

The comparator reports differences in project metadata, security roles, unit
tree, modules, entities (including native attribute metadata and access rules),
associations, pages/widgets/events, menus, microflows, nanoflows and allowed
module roles. Microflow and nanoflow bodies are normalized before comparison:
volatile UUIDs and canvas coordinates are ignored, while objects, actions,
properties and control-flow edges remain part of the snapshot.

For external Mendix validation on Linux, use the `mx` and `mxbuild` binaries
matching the exact model version:

```sh
mx check App.mpr --warnings --deprecations --best-practice --json check.json
mxbuild \
  --java-home=/path/to/jdk-21 \
  --java-exe-path=/path/to/jdk-21/bin/java \
  --target=package \
  --output=App.mda \
  --write-errors=mxbuild-errors.json \
  App.mpr
```

Compare the diagnostic JSON with the original project, not merely the exit
code: `mx check` combines warnings, deprecations and recommendations into a
nonzero status even when there are zero errors.

## Ruby model evaluations

Model expectations live in ordinary Ruby files:

```ruby
# evaluation.rb
artifact "Sales.Order", kind: :entity
reference from: "Sales.Order_Overview", to: "Sales.Order"
no_call_cycles
no_missing_internal_references
maximum_unreferenced 20, severity: :warning
forbid_dependency from: :Domain, to: :Presentation

check "orders expose a status attribute" do |project|
  project.find_artifact("Sales.Order.Status", kind: :attribute) != nil
end
```

Run them with:

```sh
bundle exec mxrb evaluate path/to/App.mpr evaluation.rb
```

Error checks produce a failing exit status; warning checks affect the score but
do not fail the command. See `examples/sudoku_evaluation.rb` for an executable
example validated against the public Sudoku fixture.

## Functional microflow tests

Runtime tests are ordinary Ruby files. The first functional slice verifies that
each selected microflow completes without an unhandled runtime exception:

```ruby
# functional_test.rb
microflow "creates an order",
          call: "Sales.ACT_CreateOrder",
          before: { call: "Sales.TEST_Prepare" },
          after: { call: "Sales.TEST_Cleanup" },
          expect: {
            return: "true",
            count: { entity: "Sales.Order", xpath: "[Status = 'Open']", equals: 1 }
          }
```

The `pass:` values are Mendix expressions and must supply every parameter of
the target microflow. MXRB validates the names before compilation. No JUnit,
Java test module or MDL is involved: MXRB generates a temporary `MxrbTests`
module, executes it as the after-startup microflow and parses its structured
runtime log back into immutable Ruby results.

Run locally with the exact Mendix toolchain and Java selected by the project:

```sh
JAVA_HOME=/path/to/zulu-21 \
  bundle exec mxrb test App.mpr functional_test.rb
```

Or keep JDK, MxBuild and runtime execution inside containers:

```sh
bundle exec mxrb test App.mpr functional_test.rb --docker
```

Docker mode builds one lightweight builder image per Java family and reuses it
for compatible Mendix versions. The exact Mendix toolchain is mounted
read-only because it is version-specific and licensed separately. The source
project is never changed: instrumentation, portable package, HSQLDB and
uploaded-file storage live in a temporary copy that is deleted after the run.

Inspect version selection and the planned container mounts without executing:

```sh
bundle exec mxrb test App.mpr functional_test.rb --plan
```

`mx check` and `mxbuild --target=portable-app-package` are mandatory gates
before runtime startup. The process stops at `[MXRB_TEST] DONE`, terminates the
runtime and returns a failing exit status if any case failed, compilation
failed, the suite did not finish or its aggregate timeout expired.
Use `--json result.json` and/or `--junit result.xml` for CI reports. JUnit is
only the XML interchange format here; MXRB writes it directly in Ruby and does
not install or execute the Java JUnit framework.

## Test coverage

The default suite runs with `bundle exec rspec`. The strict line-coverage gate
uses Ruby's native `Coverage` API:

```sh
MXRB_COVERAGE=1 bundle exec rspec
```

It writes `coverage/coverage.json`, requires 100% line coverage, and reports
branch coverage separately for visibility.

## Ruby module marketplace

```sh
mxrb module search
mxrb module search security
mxrb module add shared-kernel
mxrb module add ./local-package --target ./exported-project
```

Catalogs are JSON files loaded from the gem, a local path or HTTPS through
`--registry`. Packages contain `mxrb-module.json`; sources may be built in,
local directories or Git repositories. Installation uses a staging directory,
rejects unsafe paths and writes `.mxrb/modules.lock.json` with version, source,
ref and a SHA-256 digest of installed files.

## Native baseline and editable deep structures

`mxrb export` writes `.mxrb/native_units.json` with the original BSON payloads
as a lossless baseline and `.mxrb/native_units.rb` with every payload expanded
as editable Ruby. The generated project loads both:
`project.rb` loads it with:

```ruby
native_units File.join(__dir__, ".mxrb", "native_units.json")
evaluate File.join(__dir__, ".mxrb", "native_units.rb")
```

Each Ruby entry uses `native_unit` and `deep_structure` to expose all BSON
fields, including binary values through `bson_binary`. Editing this Ruby hash
overrides the baseline before typed writers run. Images, constants, datasets,
services, project settings, templates and newly introduced Mendix unit types
therefore remain both lossless and directly editable even without a concise
typed abstraction.
Microflow/nanoflow bodies and page/widget trees have an additional editable
representation described below.

Every flow body in the current public matrix is exported as typed Ruby. The
exporter records a canonical `body_fingerprint`: if the body is unchanged,
MXRB reuses the exact native graph; if the Ruby body changes, the fingerprint
no longer matches and the writer regenerates that graph. The fingerprint line
is generated bookkeeping and normally should not be edited by hand.

Editable flow activities currently include:

```ruby
create_object "Sales.Order", as: :order
change_object :order, set: { Status: "'Open'" }
retrieve_objects "Sales.Order", as: :orders, xpath: "[Active = true]", limit: 100
commit :order, with_events: false
delete :order
call_microflow "Sales.Process", as: :result, pass: { Order: :order }
create_variable :message, type: :string, value: "'Created'"
change_variable :message, to: "'Updated'"
show_message "Done", type: :information, blocking: true
log_message "Completed", level: :info, node: "'MXRB'"
decision "$order/Total > 100" do
  on(true) { call_microflow "Sales.ApplyDiscount" }
end
loop_over :orders, as: :order do
  commit :order
end
rescue_all { log_message "Failed", level: :error }
return_value :result
```

The DSL also covers database/association retrieval and sorting, Java,
JavaScript, nanoflow and app-service calls, show/close page, REST calls,
aggregates, casts, rollback, list operations, validation feedback, boolean and
multi-value decisions, inheritance/type decisions, iterators, while loops,
error/continue events, annotations and nested flows.

For MPR v2 exports, the manifest records the source format and `mxrb generate`
creates `mprcontents/*.mxunit` automatically for the rebuilt project.

## Page widgets

New pages and pages composed only of core controls use concise methods:
`text_box`, `number_input`, `check_box`, `date_picker`,
`reference_selector`, `drop_down`, `button`, `text`, `container`, `snippet`,
`tab_control`/`tab_page`, and `data_grid`/`column` with search bar and toolbar.

Every imported page also exports its complete page internals as a structured
Ruby hash:

```ruby
page :Dashboard do
  title "Dashboard"
  deep_structure({
    "FormCall" => {
      "$Type" => "Forms$LayoutCall",
      "Arguments" => [
        2,
        {
          "$Type" => "Forms$FormCallArgument",
          "Widgets" => [
            3,
            {
              "$Type" => "CustomWidgets$CustomWidget",
              "Name" => "Map",
              "Object" => { "Zoom" => 12 }
            }
          ]
        }
      ]
    }
  })
end
```

The concise declarations remain an architectural/readability view; when
`deep_structure` is present, edit that hash for storage-level page changes.
It is intentionally verbose but not opaque: every property can be inspected
and changed as Ruby data. BSON binary values appear as
`bson_binary("...", subtype: :generic)`. The deep structure is authoritative
when present, so edits are written instead of being overwritten by the native
baseline.

Imported menu documents follow the same rule: concise `item` declarations are
emitted for readability and dependency analysis, while their complete native
caption/action/translation structure remains editable and authoritative.

Buttons can call microflows/nanoflows or native page actions:

```ruby
button :saveButton, caption: "Save" do
  on_click action: :save_changes
end
```

Supported native actions are `:save_changes`, `:cancel_changes`, `:delete`,
and `:close_page`.

## Navigation and security

Menu documents are exported as module-level presentation navigation:

```ruby
menu :Submenu do
  item "Accounts", page: "Administration.Account_Overview"
end
```

Project security user roles are exported at `app/security/security.rb`:

```ruby
security do
  security_level "CheckEverything"
  user_role :Administrator, module_roles: ["System.Administrator"], admin: true
end
```

Module security roles are exported per module at `modules/<Module>/security/security.rb`:

```ruby
module_role :User
module_role :Administrator, description: "Full module access"
```

Page, microflow and nanoflow access can be edited with `allowed_roles`, using
qualified module role names:

```ruby
page :Account_Overview do
  allowed_roles "Administration.Administrator"
end

microflow :ChangeMyPassword do
  allowed_roles "Administration.Administrator", "Administration.User"
  allow_concurrent_execution false
  mark_as_used true
  excluded false
end
```

`allow_concurrent_execution`, `mark_as_used` and `excluded` are exported
explicitly for every imported microflow/nanoflow. They are editable booleans,
so reference/example flows that are intentionally excluded are not silently
reactivated during regeneration.

Entity access rules support `create`, `delete`, `read`, `write` and `xpath`.
Rules that cannot be represented completely—particularly legacy rules without
resolvable role names—remain native as a complete collection rather than being
partially exported.

Attribute round-trip preserves version-specific key casing and native details
that are not yet first-class DSL options, including string length, enumeration
references, date localization and calculated-value definitions. `float` and
`binary` are accepted attribute types in addition to the existing types.

## MPR v2

When an `mprcontents/` directory exists beside the MPR, unit contents are read
and written at:

```text
mprcontents/aa/bb/aabbccdd-....mxunit
```

Writes use a temporary file followed by an atomic rename, while SQLite keeps
`Contents` null and stores the content hash. The current codec accepts BSON
unit payloads. Mendix `.mxunit` encodings that are not BSON are rejected
explicitly; they are never silently replaced.

External tools such as `mxcli`
can still be useful as a manual comparison oracle when researching Studio Pro
behavior, but they are not part of the mxrb runtime or regression workflow.

See the [validation matrix](validation-matrix.md) for the public-project
round-trip matrix and the exact confidence boundary of the current engine.
# Semantic analysis in Ruby

MXRB does not require a separate query language. An opened MPR exposes its
semantic index directly as Ruby objects:

```ruby
Mxrb.open("app.mpr") do |project|
  project.references_to("Sales.Order").each do |reference|
    puts "#{reference.source.qualified_name} (#{reference.relation})"
  end

  project.callers_of("Sales.Recalculate").each do |caller|
    puts caller.qualified_name
  end

  project.callees_of("Sales.Checkout").each do |callee|
    puts callee.qualified_name
  end

  project.impact_of("Sales.Order").artifacts.each do |affected|
    puts affected.qualified_name
  end
end
```

The same operations have convenience commands: `mxrb refs`, `mxrb callers`,
`mxrb callees` and `mxrb impact`. The Ruby API is the source of truth.

## Deep rename

Writing requires an explicitly writable project and can be reviewed before
touching the MPR:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Order", to: "Invoice")

  plan.changes.each do |change|
    puts "#{change.path.join(".")}: #{change.before} -> #{change.after}"
  end

  plan.apply!
end
```

The plan updates the declaration and deep references, including Mendix member
paths such as `Sales.Order/Number`. The project index is rebuilt automatically
after applying it.

The equivalent CLI command only shows a preview:

```sh
bundle exec mxrb rename app.mpr Sales.Order Invoice
```

To write:

```sh
bundle exec mxrb rename app.mpr Sales.Order Invoice --apply
```

## Safe removal

Removal is also previewed before writing:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_remove("Sales.UnusedFlow")
  plan.apply! if plan.safe?
end
```

`mxrb remove app.mpr Sales.UnusedFlow` reports incoming references and child
units. Adding `--apply` writes only when both collections are empty. Embedded
entities, attributes and associations require a typed domain-model mutation.

## Safe move

Move a standalone unit between folders in its current module:

```ruby
plan = project.plan_move("Sales.Process", to: "Sales.Automation")
plan.apply!
```

The CLI equivalent is
`mxrb move app.mpr Sales.Process Sales.Automation [--apply]`. Folder cycles,
cross-module moves and non-container targets are rejected before writing.

## Lint and coupling

The semantic report is a Ruby object:

```ruby
report = Mxrb.open("app.mpr", &:analyze)

report.diagnostics.each do |diagnostic|
  puts "#{diagnostic.severity}: #{diagnostic.message}"
end

report.module_dependencies.each do |dependency|
  puts "#{dependency.from} -> #{dependency.to}: #{dependency.references.size}"
end
```

Project-specific rules are Ruby as well:

```ruby
public_name_rule = lambda do |_project, index|
  index.artifacts.filter_map do |artifact|
    next unless artifact.kind == :microflow
    next if artifact.name.match?(/\A[A-Z]/)

    Mxrb::Semantic::Diagnostic.new(
      :public_name,
      :warning,
      "microflow must start with uppercase: #{artifact.qualified_name}",
      [artifact],
      {}
    )
  end
end

Mxrb.open("app.mpr") do |project|
  report = project.analyze(rules: [public_name_rule])
end
```

In the CLI, `mxrb lint app.mpr` shows diagnostics and
`mxrb report app.mpr` summarizes references and coupling between modules.

## Semantic diff for Git

`Mxrb.diff` returns typed changes without exposing unstable UUIDs and visual
coordinates:

```ruby
result = Mxrb.diff("main.mpr", "feature.mpr")

result.changes.each do |change|
  puts "#{change.operation} #{change.path.join(".")}"
end
```

Each `Mxrb::Compare::Change` provides `operation`, `path`, `before` and `after`.
Convenience filters are available through `result.added`, `result.removed` and
`result.changed`.

```sh
bundle exec mxrb diff main.mpr feature.mpr
```

The command exits with status zero when the snapshots are semantically
identical and status one when differences exist.

## Structural navigation

```ruby
Mxrb.open("app.mpr") do |project|
  matches = project.search_artifacts("order", kind: :microflow)
  details = project.describe_artifact("Sales.CreateOrder")

  details.incoming.each { puts "from #{_1.source.qualified_name}" }
  details.outgoing.each { puts "to #{_1.target.qualified_name}" }
end
```

In the CLI:

```sh
bundle exec mxrb find app.mpr order
bundle exec mxrb describe app.mpr Sales.CreateOrder
bundle exec mxrb tree app.mpr Sales
```
