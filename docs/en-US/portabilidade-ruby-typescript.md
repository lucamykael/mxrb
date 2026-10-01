# Real portability between Ruby, TypeScript, and Mendix

## Primary direction: Mendix → Ruby + React/TypeScript

The conversion target is an editable Ruby backend and React/TypeScript web
application without the Mendix runtime. Rebuilding an MPR is a separate contract.
`runtime_only` does not mean uneditable: custom Ruby and React code can be fully
editable without a Studio Pro projection. `portability --require-native` audits
Ruby → Mendix, not completion of Mendix → Ruby.

The Ruby runtime still reads an internal MPR copy for metadata and graphs that
depend on it. No JVM/Mendix runtime does not yet mean no MPR baseline. Untranslated
variants, custom actions without adapters, and unsupported widgets remain gaps.

Input editability, expression conditions, read-only style, placeholder, password,
maximum length, ARIA label/required state, tab order, and autocomplete are now
exported as page Ruby options. Editing `app/pages/**/*.rb` changes the Ruby
backend's page projection without rebuilding an MPR. Supported options are applied
by React. Nested Data Views cannot unlock a read-only ancestor; unknown conditions
stay locked. Role-based/native condition variants still need translation and
must not be called functionally equivalent. Backend authorization remains separate.

Focus/change/leave actions preserve input focus and wait for writes where needed.
Server objects are no longer implicitly transient; failed writes, including 404,
are reported. Named grid selection feeds `listen_to` views. Multi-step association
sources traverse each link and stop at empty links without unscoped queries.

`spec/fixtures/ruby_frontend_editability/project.rb` and
`spec/fixtures/frontend_browser/ruby_editability_flow.json` test conditional
editing, selection, and persistence after reload in Ruby/React. Component tests
cover focus, rejected writes, expression semantics, and association traversal.
This verifies that slice, not the entire frontend or independence from every baseline.

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
