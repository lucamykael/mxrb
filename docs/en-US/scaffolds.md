# Project scaffolds

[Português](../pt-BR/scaffolds.md) · **English** · [Deutsch](../de-DE/scaffolds.md)

Every command accepts `--target DIR`, refuses to overwrite files, and wires
`evaluate`/`evaluate_dir` aggregators automatically. Run
`mxrb <command> --help` for usage, destination, and options.

The available families are project/module (`init`, `module new`), domain
(`entity`, `enumeration`, `constant`), application (`use-case`, `validation`,
`query`, `repository`, `scheduled-event`), presentation (`presentation init`,
`page`, `nanoflow`), security, infrastructure (`integration`, `published-rest`,
`consumed-rest`, `java-action`), verification (`functional-test`, `evaluation`),
design, and GitHub CI. `mxrb page new Module.Page` keeps creating a minimal
page. Adding `--chain` creates an executable vertical slice with a sample
entity, data-source microflow, editable page, actions, and a Responsive
navigation item. Three real Mendix action chains are available:

```sh
mxrb page new App.Order --chain page:microflow
mxrb page generate App.Order --chain page:nanoflow
mxrb page g App.Order --chain page:nanoflow:microflow
```

`page:microflow` calls the Runtime directly; `page:nanoflow` keeps the action
client-side; and `page:nanoflow:microflow` uses the client flow to orchestrate a
Runtime call. All modes create `ACT_LoadOrder` for the data source. Chains that
end in a microflow also create `ACT_RefreshOrder`. `page generate` and `page g`
are aliases of `page new`. Every generated chain is materialized as a valid MPR
and checked by compiler preflight.

## Page templates

In Mendix, page templates are starting points whose structure becomes a normal,
editable page. MXRB lists only patterns audited by its compiler and Runtime:

```sh
mxrb page templates
mxrb page templates --json
mxrb page new App.Landing --template starter
mxrb page new App.Empty --template blank
mxrb page new App.Operations --template dashboard
mxrb page new App.Order_NewEdit --template form-vertical
```

`form-vertical` also creates a sample entity and `ACT_Load...` DataView source.
Every template can be combined with `--chain`; for example,
`--template dashboard --chain page:nanoflow` adds a client action to the
dashboard. These names are stable MXRB contracts inspired by Mendix patterns,
not a claim that every installed Atlas or Marketplace template is silently
imported. See the [official pages documentation](https://docs.mendix.com/refguide/pages/).

Artifact commands use `new Module.Name`; project commands use `design init` and
`ci init github`. See the [entity DSL](entity-dsl.md) for all supported entity
types and associations. Published REST and Java Action create editable Ruby
adapters; their native document/action must still come from an exported
baseline or Studio Pro.
