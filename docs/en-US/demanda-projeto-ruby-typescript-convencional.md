# Requirement: conventional Ruby and TypeScript projects

## Goal

Keep Mendix-specific structure out of application-owned code except where a
reversible MPR representation makes it unavoidable. Users should develop a
normal Ruby and React + TypeScript application whether they start from a real
MPR or from an empty project.

## Required contract

- `app/` contains conventional Ruby application code.
- `frontend/src/app`, `components`, `core`, `features`, `hooks`, `layouts`, and
  `styles` belong to the developer and are never regenerated.
- `frontend/src/generated` is the only frontend boundary owned by MXRB.
- Document, widget, microflow, nanoflow, and portable-ID details remain inside
  the generated bridge.
- Exports include a lockfile, strict TypeScript, linting, formatting, component
  tests, unit tests, and a production build.
- Round-trips preserve application files byte-for-byte and regenerate stale
  generated bridge files.
- New entities and attributes use the native editor BSON shape. `required: true`
  creates a `DomainModels$RequiredRuleInfo` that can later be changed or removed.
- Common navigation icon names are materialized as valid glyph codes.

## Required certification

1. Real MPR: export, edit existing and new pages/flows using Ruby/TypeScript,
   compile, reexport, run in Chromium, and validate with official Mendix tools.
2. Greenfield project: build the application in Ruby/TypeScript, materialize its
   first MPR, reexport it, execute it, and validate it with Mendix.

Both cases must prove frontend → local flow → Ruby backend → page feedback,
stable documents, an error-free official build, and no local paths or secrets
in versioned artifacts. See
[`certificacao-ruby-typescript.md`](certificacao-ruby-typescript.md).
