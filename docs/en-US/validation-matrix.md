# MXRB validation matrix

[Português](../pt-BR/validation-matrix.md) · **English** · [Deutsch](../de-DE/validation-matrix.md)

Last updated: 2026-08-11.

The matrix exercises this pipeline using only MXRB:

```text
original MPR
  -> mxrb validate
  -> mxrb export
  -> mxrb generate
  -> mxrb validate rebuilt
  -> mxrb compare original rebuilt
```

Generated files are written outside the source repositories. Original fixtures
are never modified.

| Fixture | Mendix | Format | Units | Result |
|---|---:|---|---:|---|
| `ako/QueryApiBlogPost` | 7.17.0-rc5 | v1 | 231 | pass |
| `ako/mxcli-sudoku` (`Sudoku`) | 11.12.1 | v2 | 409 | pass; 409 `.mxunit` rebuilt |
| `bhataparnak/MendixApp` | 9.6.1 | v1 | 346 | pass |
| `ako/ConnectorKitDemo` | 7.5.0 | v1 | 222 | pass |
| `mendixlabs/TreeViewAndGridView` (`TreeviewDemo`) | 5.21.4 | v1 | 176 | pass |
| `mendixlabs/TreeViewAndGridView` (`GridViewPlayground`) | 6.10.8 | v1 | 122 | pass |

On August 11, `script/validate_matrix` repeated the matrix with **6/6 passes**:
1,506 units, 1,734 artifacts, and 3,388 references in 16.381 seconds.

## Additional local inventory

`script/certify_mprs --cycles 2 --repair-hashes` certified seven additional
MPRs through 14 consecutive round trips: **7/7 passes**, 2,799 units, 3,238
artifacts, and 4,819 references. The set covers LearnNow, SLATaskApp,
SLATaskAppNative, MyFirstModule, CourseManager, RubyBridgeSandbox, and
VetClinic.

SLATaskApp had one stale content hash and RubyBridgeSandbox had two. The gate
repaired only `Unit.ContentsHash` in temporary copies, recorded the changed
UUIDs, and preserved the original BSON bytes. Source files were not modified.
The second round trip also exposed and fixed native-widget types deserialized
as strings.

The comparator used for this matrix includes:

- project metadata and format;
- project and module security;
- the unit tree;
- entities, native attribute metadata, access rules and associations;
- pages and their complete deep widget/layout trees, events and data sources;
- menus;
- microflow and nanoflow parameters, roles, objects, actions and edges.

UUIDs and visual canvas coordinates are normalized because regeneration may
legitimately assign new identifiers or positions. Mendix names remain canonical
in the semantic snapshot; Ruby filename and identifier formatting is not used
as evidence of a model difference.

## Bugs found and fixed by the matrix

- `SecurityLevel` was reset from `CheckEverything` to `CheckNothing`.
- Unsupported microflow actions could cause partial body export and replacement.
- Microflow bodies were absent from structural comparison.
- Legacy `Attributes`/`Entities` and `NewType` key casing was not preserved.
- String lengths, enum references, date localization, calculated values and
  legacy defaults could be replaced by shallow generated values.
- Legacy access rules and entity event handlers could be dropped.
- Raw Mendix expressions could be emitted as evaluated Ruby instead of preserved
  expression strings.
- Legacy page layout containers, custom widgets and advanced widget properties
  were preserved only in the native manifest and could not be edited in Ruby.
- Page merge always preferred the old `Widgets`/`FormCall`, which could ignore
  an intentional deep Ruby edit.
- New v2 databases used `ContentsConflict` instead of the Studio Pro
  `ContentsConflicts` schema, omitted `_FormatVersion`, and stored null unit
  conflict values.
- New Mendix object IDs and graph pointers were serialized as UUID strings
  instead of 16-byte BSON GUIDs.
- Generated attributes used the nonexistent storage type
  `DomainModels$AttributeImpl`.
- The root project used `ProjectDocuments` as its own containment.
- Native folders were flattened; folders with duplicate names were collapsed.
  The comparator also collapsed duplicate-name unit summaries and missed this.
- Typed page/menu overlays introduced version-incompatible page properties and
  lost native menu captions.
- Optional nanoflow fields absent in the source were added during merge,
  producing an extra Studio Pro deprecation.
- Imported microflows always regenerated `Excluded`, `MarkAsUsed` and
  `AllowConcurrentExecution` with defaults. This could reactivate a disabled
  example flow and expose intentionally unresolved references.

## Deep editable coverage

All 264 microflow/nanoflow bodies found in this fixture set are emitted as
typed Ruby DSL. Unchanged bodies retain the exact native graph through a
canonical body fingerprint; editing the Ruby invalidates that fingerprint and
regenerates the graph.

The page audit found 1,304 nodes across 25 widget/layout types in 133 pages.
Core controls retain concise typed methods, and every imported page additionally
exports its complete Mendix payload as an editable `deep_structure({...})` Ruby
hash. This includes legacy layouts, custom widgets, list views, radio groups,
reference-set selectors, static images, text areas and advanced containers.
BSON binary values are explicit `bson_binary(...)` expressions, not a
serialized page blob. An automated regression changes a nested custom-widget
property, regenerates the MPR and verifies that the changed value was written.

Menus also retain their concise item DSL plus an authoritative deep structure
for complete captions, translations, actions and version-specific properties.

## Official Mendix 11.12.1 validation

The rebuilt Sudoku v2 project was validated with the official Linux tools from
MxBuild 11.12.1:

- `mx show-version`: recognized the rebuilt MPR as `11.12.1`;
- `mx check --warnings --deprecations --best-practice`: loaded the complete
  model with **0 errors**;
- diagnostic parity: both original and rebuilt produced exactly **23 warnings,
  1 deprecation and 6 best-practice recommendations**;
- `mxbuild --target=package`: **BUILD SUCCEEDED** and created a 12 MB MDA;
- current regression MDA: 11,941,148 bytes, SHA-256
  `fc4fb7a2ea2b4ad7cdb0fcd3296a5dbb5c4d148371aad997ab0032d2c5c0cf33`.

This validation exposed and drove the fixes listed above. The six-project MXRB
matrix was rerun from fresh targets after the fixes and all six v1/v2
round-trips passed again.

## Official Mendix 5–9 validation

The other v1 fixtures were also opened by official MxBuild binaries. Original
and rebuilt projects were tested in separate disposable project directories
with identical resources:

| Fixture | Official tool | Original vs rebuilt result |
|---|---|---|
| FirstMedix App 9.6.1 | MxBuild 9.6.1.29396 | exact diagnostic parity: 884 errors and 12 warnings; both stop on the same missing theme/widget resources |
| QueryApiBlogPost 7.17.0-rc5 | MxBuild 7.17.0 final with `--loose-version-check` | both pass model consistency and reach Java compilation; both report the same 42 missing-dependency errors |
| ConnectorKitDemo 7.5.0 | MxBuild 7.5.0 | both pass model consistency and reach Java compilation; both report the same 100 missing-dependency errors |
| GridViewPlayground 6.10.8 | MxBuild 6.10.8 | **BUILD SUCCEEDED** for both original and rebuilt |
| TreeviewDemo 5.21.4 | MxBuild 6.10.8 with `--loose-version-check` | exact normalized diagnostic parity: 1 error, 6 warnings and 8 deprecations |

The rebuilt GridView MDA is 1,501,038 bytes with SHA-256
`b92646e2a2ce47f8808b9c0624b7c68b3f11f962fefa5be28c5600f0cb628416`.
MDA archives are not expected to be byte-identical because generated package
metadata can vary between runs.

This run found one real MXRB regression in the 7.17 fixture: a reference
implementation microflow was exported without its `Excluded=true` metadata,
so the rebuilt project activated it and reported six unresolved
`UserManagement.Account` references. Flow metadata is now first-class Ruby DSL
and the fixed rebuild reaches the same Java compilation failure as the
original.

The old 6.x/7.x distributions have an optional NLog configuration that is
incompatible with modern Mono reflection. Only that logging section was
disabled in disposable copies; the MxBuild/model/runtime assemblies were not
changed. MxBuild 5.21.4 cannot be model-validated on this Linux host because it
loads WPF `PresentationFramework` plugins before reading the MPR. The same
original and rebuilt 5.21 projects were therefore compared through MxBuild
6.10.8's official in-memory upgrade. Exact 5.21 validation remains a Windows
Studio Pro/MxBuild check.

## Confidence boundary

A passing matrix demonstrates lossless behavior for the properties inspected by
`mxrb compare` on these fixtures, plus official MxBuild compatibility or
diagnostic parity for Mendix 6, 7, 9 and 11. Mendix 5 has parity through the
official 6.10 in-memory converter, but still needs an exact Windows-side 5.21
run. This is not proof of full compatibility with every Mendix metamodel
version, and unknown `.mxunit` encodings continue to be rejected rather than
guessed.

Every native unit retains `.mxrb/native_units.json` as its lossless baseline
and is also expanded into editable `native_unit` hashes in
`.mxrb/native_units.rb`. Concise typed DSLs overlay that complete Ruby
representation where available.

## Widget certification

`script/certify_widgets --browser-report REPORT.json App.mpr` is the fail-closed
gate for native web compiler and Marketplace widgets actually used by a
project. It jointly requires page/layout compilation without fallbacks, resolution of every
pluggable ID to an MPK `.mjs` entry with SHA-256, a version-owned native Rspack
build, and passing Chromium evidence that declares every exercised widget type
and ID without visible Runtime/widget errors.

Importing an MPK or compiling its bundle alone does not certify behavior.
Widgets that require a datasource, attribute, or specific parent placement only
pass in a browser scenario configured with that valid context. Future or
unexercised packages fail as missing evidence instead of inheriting a universal
compatibility claim.
The React/TypeScript frontend for `--mode ruby` has a separate track: its
Chromium report certifies those widgets without claiming that equivalent
pluggable components also passed in the Mendix Runtime.

## Ruby semantic index

The Ruby semantic index was built successfully from every original MPR in the
matrix. This exercises `find_artifact`, `references_to`, `references_from`,
`callers_of`, `callees_of`, and `impact_of` without MDL or Studio Pro:

| Mendix | Project | Artifacts | References |
|---|---|---:|---:|
| 5.21 | TreeviewDemo | 242 | 786 |
| 6.10 | GridViewPlayground | 132 | 274 |
| 7.5 | ConnectorKitDemo | 247 | 429 |
| 7.17 | QueryApiBlogPost | 252 | 414 |
| 9.6.1 | FirstMedix App | 410 | 665 |
| 11.12.1 | Sudoku | 495 | 819 |
| **Total** | **6 projects** | **1,778** | **3,387** |

Static analysis was calibrated on the same matrix:

| Mendix | Unreferenced warnings | External-reference warnings | Call cycles | Module dependencies |
|---|---:|---:|---:|---:|
| 5.21 | 18 | 0 | 0 | 18 |
| 6.10 | 10 | 3 | 1 | 4 |
| 7.5 | 23 | 3 | 0 | 5 |
| 7.17 | 13 | 6 | 0 | 6 |
| 9.6.1 | 9 | 0 | 0 | 3 |
| 11.12.1 | 9 | 0 | 0 | 6 |

The 6.10 project contains one direct recursive call. Unreferenced artifacts
remain warnings because Mendix entry points can be invoked by runtime hooks.
References to absent namespaces are external-contract warnings; missing targets
inside a module present in the MPR are errors. `System.*` references and
references from excluded documents are intentionally ignored by that rule.

The typed `Mxrb.diff` was also run for all six original/rebuilt pairs. Every
pair returned zero semantic changes. A controlled microflow rename in the 7.17
fixture was reduced to precise `changed` entries for its name and references,
instead of dumping the complete removed and added flow bodies.

## Ruby evaluations and coverage gate

The current suite contains 1,329 examples and passes with 100.00% line coverage
(23,771/23,771 executable library lines) and 100.00% branch coverage
(9,704/9,704 branches).
Run the enforced gate with:

```sh
MXRB_COVERAGE=1 bundle exec rspec
```

The Ruby evaluation CLI was also exercised against the Mendix 11.12.1 Sudoku
fixture using `examples/sudoku_evaluation.rb`. All seven checks passed for a
100.00% model score, covering artifacts, cycles, unresolved internal
references, unreferenced thresholds and a custom Ruby assertion.

## Functional runtime validation

`examples/sudoku_functional_test.rb` was executed against the original public
Sudoku 11.12.1 fixture through both MXRB runtime paths:

| Executor | Official gates | Runtime result | Elapsed |
|---|---|---|---:|
| Local disposable workspace | `mx check`: 0 errors; portable `mxbuild`: succeeded | 3/3 passed | 34.16 s |
| Docker disposable workspace | JDK 21 + ICU builder; portable `mxbuild`: succeeded | 3/3 passed | 39.52 s |

The cases invoke `Sudoku.ACT_NewEasy`, `ACT_NewMedium` and `ACT_NewHard`.
The official runtime created an ephemeral HSQLDB, ran the generated
`MxrbTests.RunAll` after-startup microflow and emitted three `PASS` records plus
`DONE`. Both executors stopped the runtime immediately afterwards. The source
MPR was copied before instrumentation and remained unchanged.

Ruby assertions now verify return expressions and persisted XPath counts. The
Docker run confirmed Game counts 1/2/3 and Cell counts 81/162/243 after the
three cases. JUnit XML remains an optional Ruby-written CI report, not a Java
test dependency.

The 11.12.1 gate now also includes an authenticated Chromium scenario: login,
Home/Orders navigation, deterministic DOM/layout/style/ARIA snapshots,
screenshots, explicit SHA-256 baseline comparison, widget/Runtime error
detection, and real logout. The three supported `page --chain` paths are each
materialized as a valid MPR and checked by compiler preflight. Dashboard and
vertical-form `page --template` outputs were also exercised in Runtime with
audited computed CSS.

## Reproducibility and performance

`script/validate_matrix` reruns all six disposable round trips and emits JSON
evidence. The current run covered 1,506 units in 14.760 seconds with zero
semantic differences. `script/benchmark` measured the Sudoku pipeline on Ruby
4.0.5: validation 0.2257 s, semantic indexing 0.7624 s, export 2.5101 s,
generation 2.4659 s and comparison 0.8822 s, totaling 6.8463 s.

Deterministic fuzz tests additionally round-trip 250 nested BSON documents and
50 atomic `.mxunit` files, including binary values, arrays and nested hashes.
