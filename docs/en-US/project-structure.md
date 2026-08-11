# Exported project structure

[Português](../pt-BR/project-structure.md) · **English** · [Deutsch](../de-DE/project-structure.md)

`mxrb export` has two explicit modes. `--mode mendix` is the default and keeps
the layered Mendix DSL tree. `--mode ruby` creates a conventional executable
Ruby application with a React + Vite frontend.

## Mendix mode

```sh
bundle exec mxrb export App.mpr app-source --mode mendix
```

This tree separates app-wide policy, module behavior, preserved native units
and filesystem assets:

```text
project.rb
.mxrb/
  native_units.json
  native_units.rb
  assets.json
app/
  security/security.rb
  navigation/navigation.rb
  design_system/design_system.rb
modules/
  ModuleName/
    domain/
    application/
    presentation/
    infrastructure/
    security/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` is orchestration. Module files own model behavior. The native
manifest preserves structures without a concise typed DSL. The asset manifest
records relative paths, sizes and SHA-256 digests for every copied project
asset.

Reconstruction validates every asset path and digest, then writes only the
manifest entries. Absolute paths, parent traversal, missing sources and
checksum mismatches fail closed.

The same tree supports all four normal workflows:

- Ruby definition to a new Mendix project;
- Ruby changes over an exported Mendix baseline;
- Mendix project to editable Ruby;
- Mendix export to Ruby and back to a structurally equivalent Mendix project.

## Ruby mode

Ruby mode can also start without an existing Mendix project:

```sh
bundle exec mxrb init CustomerPortal --mode ruby
cd CustomerPortal
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

This creates the conventional application directly with `app/models`,
`app/dtos`, `app/services`, `app/pages`, and React + Vite. A reversible Mendix
baseline is isolated under `.mxrb`; it does not dictate the editable source
layout. Materialize the current project as an MPR with:

```sh
bundle exec mxrb generate project.rb build/CustomerPortal.mpr
```

New Ruby models become entities, DTOs become non-persistent entities, and the
bidirectional declarations are synchronized into the MPR. Ruby or React code
without a native Mendix representation remains checksum-embedded and returns
unchanged on the next export. Compilation fails explicitly when a structural
change cannot be represented, preventing a silent partial conversion.

To convert an existing MPR, use:

```sh
bundle exec mxrb export App.mpr app-ruby --mode ruby
```

```text
app/
  models/
  dtos/
  services/
  pages/
config/application.rb
frontend/
  package.json
  vite.config.js
  src/{main.jsx,App.jsx,app.css}
project.rb
.mxrb/
  ruby-app.json
  runtime/App.mpr
  mendix/
```

Persistent entities become records. Non-persistent entities become DTO classes
and always use the `_dto.rb` suffix, avoiding ambiguous `_2.rb` names. Services
are ordinary Ruby classes and initially delegate to the pure-Ruby native
interpreter. Pages expose native metadata to the React frontend.

Install the Ruby and frontend dependencies once, then start both processes with
one command:

```sh
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

`mxrb run` supervises the loopback Ruby JSON API and Vite development server.
Vite proxies `/api` to Ruby. Use `--server-port` for the backend port and
`--client-port` for the frontend port. `--no-frontend` starts only the API.
The former `--api-port` and `--port` names remain compatibility aliases.
The global `--no-progress` option is optional and only hides progress output.

Two opt-in stacks add familiar Ruby conventions without changing the default
Ruby mode:

```sh
bundle exec mxrb init ServiceDesk --mode ruby --flymetothemoon
bundle exec mxrb export App.mpr app-rails --mode ruby --onrails
```

`--flymetothemoon` adds Sinatra, Puma, ActiveRecord, Rake and RSpec.
`--onrails` adds Rails, Puma, ActiveRecord and RSpec. Both keep React + Vite as
the integrated application frontend and run through the same `mxrb run .`
command. ActiveRecord migrations own Ruby-only tables; the MXRB manifest stays
authoritative for the Mendix domain model and its round-trips.

## Browser domain-model diagram

Open one or more Mendix module domain models in a DBeaver-inspired ER diagram:

```sh
bundle exec mxrb diagram-er App.mpr --module Sales
bundle exec mxrb diagram-er App.mpr --module Sales --module Billing \
  --output build/App-layout.mpr
```

The sidebar can select several modules together and displays associations
between them. The browser also supports entity search, drag-and-drop
positioning, zoom, fit, auto-arrange, grid, attribute visibility, relationship
routing and draggable source/target anchors. Persistent entities are blue,
DTO/non-persistent entities yellow, and OQL views green. **Save layout to MPR**
writes positions and local-association anchors to native Mendix fields;
cross-module anchors, which have no native BSON field, use isolated MXRB visual
metadata in the same safe copy. The default copy is `App.domain-layout.mpr`; an
existing output requires `--force`.

**Export PNG** downloads a high-resolution image of the selected modules using
the current colors, attributes and routes. PNG export does not modify the MPR;
save the layout separately when those positions must survive a round-trip.

Foreground mode remains available and occupies the terminal until `Ctrl+C`.
Use the managed lifecycle to keep the ER editor in the background; stopping it
preserves the layout copy and neither the source MPR nor its files are edited or
removed:

```sh
bundle exec mxrb diagram-er up App.mpr --module Sales
bundle exec mxrb diagram-er status App.mpr
bundle exec mxrb diagram-er down App.mpr
bundle exec mxrb diagram-er up App.mpr       # resume the same copy
bundle exec mxrb diagram-er destroy App.mpr --yes
```

`destroy` stops the server and removes only the copy and external contents
created by that lifecycle. Management uses a private authenticated loopback
endpoint; state and token are stored in permission-restricted local files.

## UML diagrams

UML is an additional implementation independent from the ER editor. It uses
port 4569 and does not change domain-model layout. The viewer combines class,
microflow activity and call-sequence diagrams rendered with Mermaid:

```sh
bundle exec mxrb uml App.mpr
bundle exec mxrb uml App.mpr --export=class --module Sales
bundle exec mxrb uml App.mpr --export=activity \
  --microflow=Sales.CreateOrder --format=plantuml
bundle exec mxrb uml App.mpr --export=sequence \
  --root=Sales.CreateOrder --depth=3
bundle exec mxrb uml App.mpr --export=sequence --module=Sales
```

Without `--export`, the unified viewer is served at
`http://127.0.0.1:4569`. Text export defaults to Mermaid; select PlantUML with
`--format=plantuml`. Sequence diagrams accept either a depth-limited root or
all calls internal to one module.

## Version transitions and round-trips

Both modes retain the stable Mendix IDs and complete native baseline required
for upgrades, downgrades and repeated round-trips. In Ruby mode, model/DTO
declarations are reverse-compiled into the MPR. Ruby service bodies and React
sources are stored with SHA-256 checksums in the MXRB source table inside the
MPR, so a later `--mode ruby` export restores the exact edited files.

Native Mendix behavior remains authoritative for constructs with no semantic
Ruby-to-Mendix compiler yet; the coverage manifest records that status instead
of silently claiming a conversion. The preserved Ruby/React source survives a
Mendix round-trip even when it has no direct Studio Pro representation.

[Back to the documentation index](README.md)
