# MXRB validation matrix

[Português](../pt-BR/validation-matrix.md) · **English** · [Deutsch](../de-DE/validation-matrix.md)

Last updated: 2026-07-29.

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
- final regression MDA: 11,941,205 bytes, SHA-256
  `8effd1b0816a29b819d8f159e4a143bbf308c4c0b2e8bced7e9f53ca0f487658`.

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

Units outside the implemented domain/flow/page surfaces still use
`.mxrb/native_units.json` as their lossless baseline. Within flow bodies and
page/widget trees in this matrix, content is now represented in editable Ruby,
either by concise typed DSL or by a complete structured Ruby hash.

## Ruby semantic index

The Ruby semantic index was built successfully from every original MPR in the
matrix. This exercises `find_artifact`, `references_to`, `references_from`,
`callers_of`, `callees_of`, and `impact_of` without MDL or Studio Pro:

| Mendix | Project | Artifacts | References |
|---|---|---:|---:|
| 5.21 | TreeviewDemo | 241 | 771 |
| 6.10 | GridViewPlayground | 131 | 269 |
| 7.5 | ConnectorKitDemo | 246 | 416 |
| 7.17 | QueryApiBlogPost | 251 | 401 |
| 9.6.1 | FirstMedix App | 409 | 656 |
| 11.12.1 | Sudoku | 495 | 817 |
| **Total** | **6 projects** | **1,773** | **3,330** |

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

The suite contains 92 examples and passes with 100.00% line coverage
(4,279/4,279 executable library lines). Branch coverage is recorded separately
and currently measures 82.77% (1,427/1,724); it is not presented as 100%.
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
| Docker disposable workspace | JDK 21 + ICU builder; portable `mxbuild`: succeeded | 3/3 passed | 37.92 s |

The cases invoke `Sudoku.ACT_NewEasy`, `ACT_NewMedium` and `ACT_NewHard`.
The official runtime created an ephemeral HSQLDB, ran the generated
`MxrbTests.RunAll` after-startup microflow and emitted three `PASS` records plus
`DONE`. Both executors stopped the runtime immediately afterwards. The source
MPR was copied before instrumentation and remained unchanged.

This proves runtime completion and exception handling for the current slice.
Assertions over returned values and persisted state remain an explicit next
step; the result is not represented as broader end-to-end UI coverage.
