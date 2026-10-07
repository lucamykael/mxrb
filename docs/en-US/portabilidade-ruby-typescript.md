# Real portability between Ruby, TypeScript, and Mendix

## Generating queryable OQL views

Declaring `oql_view` preserves the entity persistability flag. New views use
the persistent default required by Mendix database retrieval; the OQL source
still prevents physical SQLite table creation. Previously, generation forced
`Persistable=false`, causing MxBuild to reject retrieve activities. Two builds
and two runtimes in the Windows VM passed after the fix, with identical source
and rebuilt results and unchanged hashes.
[Evidence](../evidence/oql-view-persistence-2026-10-07.json).
Executing view queries in the Ruby runtime remains unimplemented.

## Nanoflow Commons storage

`GetStorageItemString`, `SetStorageItemString`, `RemoveStorageItem`,
`StorageItemExists` and `ClearLocalStorage` have Web adapters selected by the
original source SHA-256. Model parameters are `Key` and `Value`. They preserve
required key/value errors, missing versus empty stored strings, removal and
clearing. `ClearLocalStorage` clears the entire current origin, as the original does.

Validation: 60 original JavaScript comparisons, 176 frontend tests, 51 Chromium
steps without MPR access, and two builds/two runtimes in the Windows VM with
identical Ruby results and unchanged hashes. All 2,326 Ruby examples passed
with 100% line/branch coverage. Real Sudoku audit and identical rebuild passed.
[Evidence](../evidence/commons-storage-2026-10-07.json).
Scope is Web `localStorage`; React Native `AsyncStorage` is not implemented.

## Nanoflow Commons actions and lists

Export registers `Base64Encode`, `Base64Decode`, `GetGuid`, `GetPlatform` and
`FindObjectWithGUID` only when implementation hashes match verified sources.
Base64 uses `js-base64` 3.7.7, the native reference version. Registration keeps
the model parameter `EntityObject` and the Feedback adapters together. Exported
nanoflows also create lists and add, remove or clear objects while preserving
references to the same list.

Validation passed 22 comparisons with original JavaScript, 169 frontend tests
and 13 Chromium steps without MPR access. Two builds and runtimes in the Windows
VM confirmed identical original/round-trip results without modifying sources.
The scenario certifies Web; environment detection is not certification of a
React Native or Cordova application.
[Evidence](../evidence/nanoflow-commons-2026-10-07.json).

## CustomChart with Plotly

`CustomChart` loads Plotly 3.0.1 on demand and applies the model's JSON data,
layout and configuration. Static and attribute traces are concatenated; context
changes redraw the chart. Dimensions, height limits, legends, axes and the
mode bar are preserved. Clicking stores the first point's `bbox` in the event
attribute, dispatches the configured action and clears the attribute. Pending
actions are guarded and the graph is purged when its component unmounts.

Acceptance compares traces, title, scale, size and click behavior before/after
an update. The frontend passed 160 tests; Chromium passed ten steps without
MPR access. The full engine adds approximately 1.33 MB gzip when requested.
The internal playground/editor, its initialization effects on sample data and
certification of every trace type are outside this contract. Other chart widgets
retain their previous option scope.

The Windows VM passed both builds and runtimes, original and rebuilt, with
results identical to Ruby and unchanged input hashes.
[Evidence](../evidence/custom-plotly-2026-10-07.json).


## Browser storage actions

Three Feedback Module actions receive TypeScript adapters when their original
source hash matches: reading a value, reading `ShowEmail`, and writing `ImageB64`.
Registration preserves model parameter names, including case. Invalid JSON,
missing values and storage failures retain the verified implementation behavior.

All 33 comparisons with original JavaScript passed. Ruby Chromium acceptance
ran ten steps without MPR access, including persistence after navigation. The
Windows VM certified the original and rebuilt projects with identical results.
Customized sources, native AsyncStorage and offline synchronization remain
outside this contract. See the [evidence](../evidence/feedback-storage-2026-10-07.json).

## Java adapters selected by verified source

Export recognizes two Feedback Module implementations by the Java source's
SHA-256: `ValidateEmail` and `XSS_Sanitizer`. Only verified versions produce
explicit registrations in `config/adapters.rb`; absent or modified sources
still require a project adapter. Runtime execution uses Ruby without an MPR
or JVM. Registrations remain editable Ruby code.

Tests compare 32 inputs with the original Java, including Unicode, empty and
null values. The legacy `XSS_Sanitizer` preserves its regular-expression
behavior; it does not replace HTML escaping or an application's sanitization
policy. Other Java/JavaScript actions and external integrations still require
their own implementation and acceptance.

## Structured captions

Captions support translations, fallback text, attribute/expression parameters,
number/date formatting and references to page, snippet or widget objects. Ruby
declarations preserve this metadata across roundtrips. The frontend uses the
selected locale and retains transported Decimal precision beyond the exact
Number range. Updating a series preserves its context.

The chart-captions scenario compares names and values before/after a change in
the native runtime. Unknown date patterns are rejected explicitly. Advanced
Plotly visual options remain a separate workstream.

## Decimal precision

Ruby uses `BigDecimal` and the frontend uses `decimal.js`. Decimal literals,
arithmetic and comparisons avoid intermediate `Float`/`Number` conversions.
Division uses the installed 11.12.1 runtime's 38 significant digits. `round`
honors `HalfUp`/`HalfEven`; export retains the project's `DecimalScale`.
`floor`, `ceil`, `abs` and unformatted `parseDecimal` also use exact values.

The internal API transports Decimal as `{"__mxrb_decimal":"9007199254740993.12345678"}`.
TypeScript extensions should use `bridge/decimal` helpers. Fields, page parameters,
filters, sorting, drafts and nanoflows preserve this value. Chart coordinates
convert to floating point at the presentation boundary.

SQLite stores canonical decimal `TEXT`, applies project scale/rounding at commit
and rejects values outside the native range. Existing `REAL` columns migrate
without dropping rows; precision lost in older writes cannot be recovered.
External SQL must use decimal comparisons rather than SQLite's textual ordering.
API clients must adopt the decimal tag alongside the regenerated frontend.
Localized parsing/formatting with Java patterns remains outside this contract.

[Decimal evidence](../evidence/decimal-runtime-2026-10-06.json).

## Calendar expressions

Ruby and TypeScript evaluate date creation, additions/subtractions from milliseconds
to years, period trimming and millisecond epoch conversion. Calendar operations
support UTC variants. Ruby uses the security context's IANA time zone; the frontend
uses the browser zone or an explicit evaluator `timeZone`. Subsequent requests do
not inherit the previous user's zone. Month/year shifts clamp to the final valid
day; elapsed hours and smaller units differ from calendar days across DST.

Local tests cover New York, Lord Howe and Apia transitions. The native compatibility
matrix adds 16 UTC cases in both source and round-trip projects; local tests alone
do not establish native equivalence. Localized parsing/formatting and date differences
remain separate contracts.


[Calendar evidence](../evidence/calendar-expressions-2026-10-06.json).

## Stacking and point actions — October 6, 2026

Bar and column charts support `barmode: "stack"`, accumulating category bases
in series order, including negative and zero values. Axis bounds include bases
and totals. `staticOnClickAction` and `dynamicOnClickAction` use the page event
runtime with the point record, confirmation and execution locking. Points
support click, Enter and Space; the accessible table also exposes the action.

For aggregated series, selection uses the point index in the ordered source
items, matching the certified Mendix Charts package. This is not necessarily
the first record in the aggregated category. Point updates preserve the page
context and its fields. The `chart-interactions` scenario covers horizontal and
vertical stacks, aggregate clicks, negative values and a newly created series.

Horizontal bar aggregation remains unsupported: the Charts package groups by the numeric axis and can concatenate labels. The Ruby runtime reports this limitation explicitly. Horizontal certification uses unaggregated points, including repeated categories.

## Dynamic chart series — October 6, 2026

Line and column charts support dynamic series grouped by the configured
attribute, with source ordering and independent aggregation per group. Data
changes update existing points and add new groups. Typed Ruby properties accept
`caption("Region {1}", parameters: ["$currentObject/App.Point.Region"])`;
the frontend evaluates each parameter against the series record. Numeric and
string values with the same spelling remain separate groups.

Tests cover simple expression and attribute parameters. Translations, custom
formatting and references to other page variables are not certified by this
caption projection. Stacking, point actions and advanced Plotly options remain
outside this increment. The Windows workflow runs the new `chart-series`
scenario against both source and rebuilt models.

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

## Primary direction: Mendix → Ruby + React/TypeScript

The conversion target is an editable Ruby backend and React/TypeScript web
application without the Mendix runtime. Rebuilding an MPR is a separate contract.
`runtime_only` does not mean uneditable: custom Ruby and React code can be fully
editable without a Studio Pro projection. `portability --require-native` audits
Ruby → Mendix, not completion of Mendix → Ruby.

Legacy exports may still read an internal MPR copy. New exports with
`runtime_model: ruby` build their runtime model from Ruby definitions. Untranslated
variants, custom actions without adapters, and unsupported widgets remain gaps.

Input editability, expression conditions, read-only style, placeholder, password,
maximum length, ARIA label/required state, tab order, and autocomplete are now
exported as page Ruby options. Editing `app/pages/**/*.rb` changes the Ruby
backend's page projection without rebuilding an MPR. Supported options are applied
by React. Nested Data Views cannot unlock a read-only ancestor; unknown conditions
stay locked. Module roles are evaluated together with supported expressions;
other native variants require their own contracts. Backend authorization remains separate.

Focus/change/leave actions preserve input focus and wait for writes where needed.
Server objects are no longer implicitly transient; failed writes, including 404,
are reported. Named grid selection feeds `listen_to` views. Multi-step association
sources traverse each link and stop at empty links without unscoped queries.

`spec/fixtures/ruby_frontend_editability/project.rb` and
`spec/fixtures/frontend_browser/ruby_editability_flow.json` test conditional
editing, selection, and persistence after reload in Ruby/React. Component tests
cover focus, rejected writes, expression semantics, and association traversal.
This verifies that slice, not the entire frontend or independence from every baseline.

Radio groups support boolean/enumeration choices, captions, horizontal/vertical
layout, keyboard selection, persistence and group focus/leave events. Inherited
read-only policies remain enforced. Unknown values are reported without mutation.
Both bare and qualified enum values are recognized; writes preserve their incoming
representation, and enum-literal conditions recognize both without conflating
different qualified types. Exported enumeration values/captions are read from Ruby
definitions, with a manifest fallback for unloaded legacy definitions. Reload the
application after editing enumeration source. Applications using `runtime_model: ruby`
discover loaded declarations and reconcile removals and renames; legacy entries
need a fresh export. The manifest remains private reconstruction metadata rather
than a manually maintained runtime catalog.

Page-title widgets use the loaded Ruby page title. Tabs show one panel, support
arrow/Home/End navigation and retain mounted drafts in previously opened panels;
unopened panels load on demand. The `ruby_frontend_core_widgets` fixture and
`frontend_browser/ruby_core_widgets_flow.json` scenario test these behaviors,
enum-based editability and persistence. Unprojected native tab variants remain open.

MXRB reports every Ruby application artifact as `native` (materialized as an
editable MPR document), `preserved_native` (kept losslessly in the Mendix
sidecar), or `runtime_only` (requires the MXRB runtime).

```bash
bundle exec mxrb portability .
bundle exec mxrb portability . --json
bundle exec mxrb portability . --require-native
```

The last command fails when runtime-only code remains. Ruby entities and their
attribute constraints materialize in the domain model. Supported microflow and
nanoflow graphs are exported with editable `native` blocks. Pages intended for
Studio Pro must use `Page.native`; an application-owned React route remains
React code and is reported honestly.

Build React/TypeScript that must run inside Mendix as an official pluggable
widget:

```bash
bundle exec mxrb widgets new OrderSummary widgets-src
bundle exec mxrb widgets build widgets-src/OrderSummary --project "$PROJECT_ROOT"
bundle exec mxrb widgets sync project.rb build/App.mpr
```

The browser scaffold uses an HttpOnly, SameSite session cookie and CSRF tokens,
not a bearer token in `localStorage`. Set `MXRB_SECURE_COOKIES=true` under HTTPS.

For LazyVim, install dependencies and open the project with `nvim .`. Useful
bindings include `gd`, `gr`, `K`, `<leader>ca`, `<leader>cr`, `<leader>cf`, and
`<leader>xx`.

Official references:

- <https://docs.mendix.com/apidocs-mxsdk/apidocs/pluggable-widgets/>
- <https://www.npmjs.com/package/@mendix/generator-widget>
