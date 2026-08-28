# Real portability between Ruby, TypeScript, and Mendix

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
