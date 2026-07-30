# Architectural patterns

**English** · translation pending — see `PENDING_TRANSLATION` in
`spec/documentation_spec.rb`

This page collects the engineering patterns MXRB applies consistently. They
explain *why* the public API looks the way it does and what guarantees each
pattern buys. For the module layout itself, see
[project structure](project-structure.md).

## 1. Ruby-first, single public interface

Ruby is the only public language. Everything MXRB can do is reachable from
`Mxrb` module functions and the `Project` object they return:

```ruby
Mxrb.open("Shop.mpr", readonly: false) do |project|
  project.find_artifact("Sales.Order")
  project.plan_rename("Sales.Order", to: "Invoice").apply!
end
```

There is no MDL, no parallel query language and no second configuration
syntax. Project-specific lint rules, evaluations and functional tests are
ordinary Ruby files too. External Mendix tools (`mx`, MxBuild, the Runtime)
are optional compatibility gates executed afterwards — never a runtime
dependency of the Ruby core.

## 2. The CLI is a thin adapter

`bin/mxrb` parses arguments, calls the Ruby API and prints results. It holds
no logic of its own. Every command is a one-line delegation:

- `mxrb generate` → `Mxrb.define`
- `mxrb export` → `Mxrb::Exporter`
- `mxrb validate` → `Mxrb::Integrity::Validator`
- `mxrb compare` / `mxrb diff` → `Mxrb.compare`
- `mxrb rename|remove|move ... [--apply]` → `project.plan_*` (+ `apply!`)
- `mxrb refs|callers|callees|impact` → the semantic index
- `mxrb lint` / `mxrb report` → `project.analyze`
- `mxrb evaluate` → `Evaluation::Suite`
- `mxrb test` → the functional runtime executor
- `mxrb module search|add` → the marketplace catalog and installer

A consequence: anything shown in this documentation as a CLI command has an
equivalent, more expressive Ruby form. When in doubt, trust the Ruby API.

## 3. Typed DSLs over a lossless baseline

MXRB never discards what it cannot yet express concisely. Export writes two
baseline files beside the project:

- `.mxrb/native_units.json` — the original BSON payloads, lossless.
- `.mxrb/native_units.rb` — every payload expanded as editable Ruby
  (`native_unit` + `deep_structure` hashes, binary values as `bson_binary`).

Generation restores the baseline first, then overlays the typed structures
that Ruby explicitly owns. Editing the deep Ruby hash overrides the baseline
before typed writers run. Images, constants, datasets, services, project
settings, templates and even unit types introduced by future Mendix versions
therefore survive round trips and stay editable, without waiting for a typed
abstraction to exist.

## 4. Fingerprint-based flow reuse

Every exported flow body carries a canonical `body_fingerprint`:

- Body unchanged → the exact native graph is reused byte-for-byte.
- Body edited → the fingerprint no longer matches and the writer regenerates
  that flow graph.

This keeps round trips stable while making edits deterministic: a change in
Ruby always wins over the stored native form, and untouched flows are never
accidentally rewritten.

## 5. Plan / preview / apply! for every mutation

No semantic operation writes on first contact. Each one builds a plan:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Order", to: "Invoice")
  plan.changes.each { puts "#{_1.path.join(".")}: #{_1.before} -> #{_1.after}" }
  plan.apply! # the only line that writes
end
```

Guarantees shared by rename, remove, move, extract, inline and domain
mutation plans:

- full preview of changes and affected units before anything is written;
- validation up front (name rules, collisions, references, child units,
  container legality);
- `apply!` writes inside an MPR transaction, so a failure mid-apply leaves
  the database unchanged;
- the semantic index is rebuilt after applying;
- re-applying an already-applied plan is blocked;
- the CLI previews by default and only writes with `--apply`.

See [semantic refactoring](semantic-refactoring.md) for each operation.

## 6. Atomic `.mxunit` writes (MPR v2)

In v2 projects, unit contents live in
`mprcontents/aa/bb/<uuid>.mxunit`. Writes go to a temporary file in the same
directory followed by an atomic rename; SQLite keeps `Contents` null and
stores only the content hash. Readers never observe a half-written payload.
Non-BSON `.mxunit` encodings are rejected explicitly — MXRB raises rather
than guessing.

## 7. Transactions and rollback at the storage boundary

`apply!` implementations wrap their mutations in the MPR transaction. The
marketplace installer follows the same philosophy on the file system: it
installs into a staging directory, moves the previous module to a backup
location during update, and restores it if the final move fails.

## 8. Marketplace: catalog → staging → lockfile

Module installation is deliberately boring and auditable:

1. A JSON catalog (built-in, local path or HTTPS via `--registry`) resolves a
   name to a package source: built-in, local directory or Git repository.
2. Files are copied into a staging directory; path traversal outside the
   target is rejected.
3. Dependency and Mendix-version requirements from `mxrb-module.json` are
   checked before writing.
4. `.mxrb/modules.lock.json` records version, source, ref and a SHA-256
   digest of the installed files.

```sh
bundle exec mxrb module search security
bundle exec mxrb module add shared-kernel --target ./my-project
```

## 9. Errors are typed and explicit

The `Mxrb::Error` hierarchy separates storage problems (`NotMprError`,
`SchemaError`, `SerializationError`) from usage problems (`ReadOnlyError`,
`ValidationError`) and from toolchain/marketplace failures. Unknown encodings
and corrupt structures raise; they are never silently repaired or dropped.
Preservation of an unknown structure is a compatibility mechanism, not data
loss — but rejection of an unknown *encoding* is a hard stop, because writing
back a guess would corrupt the project.

## 10. Coverage as a gate, not a metric

The suite enforces 100% line coverage (with branch coverage tracked toward
the same bar) through `MXRB_COVERAGE=1 bundle exec rspec`, using Ruby's
native `Coverage` API. Defensive branches unreachable through the public API
are excluded explicitly with `:nocov:` markers, each one a reviewed statement
that the path cannot be produced by a well-formed project. See
[conventions](conventions.md).
