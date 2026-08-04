# Conventions

[Português](../pt-BR/conventions.md) · **English** · [Deutsch](../de-DE/conventions.md)

Conventions that hold across the MXRB codebase, its tests and its
documentation. Some are enforced mechanically; the rest are enforced in
review. Writing-style guidance for exported projects lives in
[writing projects](writing.md).

## Naming

- Mendix-qualified names (`Sales.Order`) are canonical everywhere: in the
  model, in comparisons, in errors. Ruby never renames the underlying
  artifact.
- Ruby files use `snake_case`; classes use `CamelCase`; symbols may adapt a
  Mendix name for readability without changing its identity.
- Public API methods read as verbs or queries (`plan_rename`, `apply!`,
  `references_to`, `impact_of`); bang methods write, non-bang methods plan or
  read.
- Plan objects expose `changes` and `apply!`; report objects expose typed
  collections (`diagnostics`, `call_cycles`, `module_dependencies`).

## Error handling

- Raise typed errors from `Mxrb::Error` downward; rescue `StandardError` only
  at execution boundaries (CLI, runtime executor, installer cleanup).
- Unknown encodings and corrupt structures are rejected explicitly. A
  non-BSON `.mxunit` raises instead of being overwritten by trial; an
  unexpected change to a file after a migration preview raises
  `SerializationError` instead of writing stale content.
- Preservation and rejection are different answers to different questions: an
  unknown *structure* is preserved losslessly; an unknown *encoding* is a
  hard stop.
- Read-only opens never write: cache persistence, plan application and
  version migration all require `readonly: false`.

## Testing

- `bundle exec rspec` is the default suite; everything must pass.
- CI sets `MXRB_LINE_COVERAGE_MIN=100` and `MXRB_BRANCH_COVERAGE_MIN=100`; the
  local helper defaults to 100/100 when those variables are omitted.
  `bundle exec ruby script/branch_report.rb` lists uncovered branches by file
  and line.
- Coverage uses Ruby's native `Coverage` API, not an external gem. Defensive
  branches that only fire on corrupt or malformed input — states the writer
  can never produce — are excluded with `# :nocov:` markers, inline or as
  region toggles. Each exclusion is a reviewed claim about reachability, not
  a way to skip hard tests.
- Deterministic fuzzing covers BSON documents and `.mxunit` atomic writes.
- Evidence scripts (`script/validate_matrix`, `script/benchmark`) exist so
  compatibility claims can be re-run instead of trusted.
- Example files under `examples/` are executable documentation and are
  validated against the public fixtures.

## Documentation and localization

- Public documentation ships in three locales with identical file sets:
  `docs/pt-BR`, `docs/en-US`, `docs/de-DE`, plus root READMEs per language.
  `docs/README.md` is only the language selector.
- `spec/documentation_spec.rb` enforces, for every Markdown file in the
  repository:
  - locale file-set parity across all three languages;
  - no broken relative links;
  - no internal workflow traces (tool-continuation notes, model or tooling
    references) — public docs describe the project, not the process that
    wrote them;
  - no Portuguese prose in the English writing guide.
- Documentation states limits as plainly as capabilities. Unsupported cases
  (for example non-BSON `.mxunit` payloads, or exact Mendix 5 execution
  requiring Windows/Studio Pro) are documented as limitations, not omitted.
- Relative links are preferred between pages so locale trees stay
  self-contained.

## Code style

- `# frozen_string_literal: true` everywhere.
- Immutable value objects (`Data.define`, frozen collections) cross public
  boundaries; mutation stays inside writers and transactions.
- `bundle exec rubocop` is the gradual static-quality gate.
- Make the smallest change that satisfies the requirement; the plan objects
  and the lockfile exist so that review can always see exactly what a write
  will do before it happens.
