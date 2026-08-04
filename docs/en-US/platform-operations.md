# Operations, lifecycle, and Marketplace

## Diagnostics, benchmarks, and evolution

```sh
mxrb doctor .
mxrb benchmark App.mpr --iterations 5 --json
mxrb project inspect . --json
mxrb upgrade --mendix 11.12.1 --target .
mxrb upgrade --mendix 11.12.1 --target . --apply
mxrb migrate plan .
mxrb migrate check .
```

`doctor` checks the Ruby project, aggregators, MPR, and local toolchain.
`benchmark` measures opening, semantic indexing, and validation. Upgrades are
previews unless `--apply` is passed. Migration generates into a temporary area
and compares that result with the current MPR; `check` fails on model drift.

## Frontend migration and acceptance

```sh
mxrb frontend migrate App.mpr --json
mxrb frontend migrate App.mpr --apply --json
script/frontend_acceptance App.mpr -o frontend-round-trip.json
script/frontend_acceptance App.mpr --mxbuild /path/to/mxbuild -o frontend.json
script/frontend_acceptance App.mpr --mx /path/to/mx -o frontend-diagnostics.json
script/frontend_lifecycle_acceptance --version 11.12.1 --mx /path/to/mx \
  --mxbuild /path/to/mxbuild --strict-warnings -o frontend-lifecycle.json
```

`mxrb frontend migrate` is an immutable, fail-closed preview by default. For
Mendix 10 and 11 it plans installed pluggable-widget schema updates, legacy
layout-row weights, and design-property normalization from the package XML.
`--apply` writes only a safe plan in one MPR transaction; unknown configured
properties, an unsupported generation, or a unit changed after preview block
the write. Neither preview nor apply invokes Mendix tooling.

`script/frontend_acceptance` is the reproducible 10/11 gate. It validates the
source and rebuilt MPRs, requires a compatible native preflight on both,
exports to Ruby and rebuilds, compares model structure, and verifies complete
asset inventories, bytes, SHA-256 checksums, and Marketplace provenance. The
provenance boundary includes `.mxrb/marketplace.lock.json`, the package cache,
and `.mxrb/marketplace-originals`; missing, changed, or unexpected files fail
the gate. The accepted renderer matrix now covers Forms tables,
`ListViewXPathSource`, listen-target object properties, structured page-variable
mappings, and Combo-box enumerations. Its preflight baseline fell from 28 to 0
findings on 10.24 and from 20 to 0 on 11.12.

Without `--mxbuild`, the report scope is `round_trip` and `frontend_ready`
remains unset. With `--mxbuild`, MxBuild is a read-only external oracle and the
scope becomes `frontend`; it never generates, mutates, or repairs the project.
The live oracle accepts success only when MxBuild exits zero and produces a
non-empty MDA; a nonzero toolchain exit without reported model errors fails
closed instead of being certified as a clean model.
On August 4, 2026, the safe migration completed the accepted 10.24.0.73019 and
11.12.1 matrix: source and rebuilt projects returned zero MxBuild errors and
both reports set `frontend_ready` to `true`.

`script/frontend_lifecycle_acceptance` creates an app exclusively through the
CLI, generates its MPR, exports it to Ruby, changes Home and navigation, adds
an entity, form, microflow, nanoflow, and asset, regenerates, exports again,
and requires a structurally identical rebuild. On the official 10.24.0.73019
and 11.12.1 matrix, source and rebuilt projects completed with zero errors,
warnings, deprecations, or recommendations in `mx check`, plus zero MxBuild
errors.

`--mx` runs the official read-only checker with warnings, deprecations, and
best-practice recommendations enabled. It validates the checker's exit bitmask
and compares normalized source/rebuilt signatures. The accepted 10.24 fixture
has 0 errors, 173 package-owned warnings, 0 deprecations, and 2 Kafka
recommendations; 11.12 has 0 errors, 10 package-owned warnings, 0 deprecations,
and the same 2 recommendations. Source and rebuilt JSON are byte-identical in
both generations, so these observable package diagnostics do not represent
MXRB round-trip drift.

## Official and community Mendix Marketplace

MXRB uses the documented Mendix Marketplace Content API. Create a PAT with the
`mx:marketplace-content:read` scope, then authenticate once:

```sh
cp .env.example .env
# Set MXRB_MENDIX_PAT in .env; never commit the file.
mxrb marketplace login --pat-file .env
mxrb marketplace search "Community Commons"
mxrb marketplace show 170
mxrb marketplace versions 170 --mendix-version 11.12.1
mxrb marketplace pull 170 --mpr MyApp.mpr
mxrb marketplace pull 170@3.4.0 --mpr MyApp.mpr
mxrb marketplace dependencies CommunityCommons --mpr MyApp.mpr
mxrb marketplace dependencies CommunityCommons --mpr MyApp.mpr --apply
mxrb marketplace dependencies CommunityCommons --mpr MyApp.mpr --apply-resolved
mxrb marketplace update 170@3.5.0 --mpr MyApp.mpr
mxrb marketplace update 170@3.5.0 --mpr MyApp.mpr --apply
mxrb marketplace remove CommunityCommons --mpr MyApp.mpr
mxrb marketplace remove CommunityCommons --mpr MyApp.mpr --apply
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr MyApp.mpr
mxrb marketplace audit --target . --mendix-version 11.12.1
mxrb marketplace list
mxrb marketplace verify
```

The recommended login mode stores only the absolute `.env` path in
`~/.config/mxrb/credentials` (or `$XDG_CONFIG_HOME/mxrb/credentials`). MXRB
does not copy, move, chmod, or rewrite the referenced file; it reads it when an
official Marketplace operation needs authentication. New scaffolds ignore
`.env` and provide a secret-free `.env.example`.

`mxrb marketplace login --store-pat` is an explicit managed-storage opt-in;
the command displays its JSON destination and `0600` mode before prompting.
`MXRB_MENDIX_PAT_FILE=/path/.env` works without persisting a reference. Run
`mxrb marketplace login --help` for accepted formats and precedence.

Official search includes public content and company-private content visible to
the PAT owner. Filters include `--private`, `--public`, `--approved`, and
`--published-since YYYY-MM-DD`. `show` exposes publisher, component type,
support category, license, privacy, company approval, and latest release.
`versions` exposes compatibility, release notes, and regular, vulnerable, or
security-fix status including CVE/CWE identifiers.

With `--mpr`, MXRB reads the package's `package.xml` and embedded
`project.mpr`, then imports the complete module unit tree directly through
Ruby/SQLite/BSON. It does not invoke `mx`, `mxcli`, Studio Pro, or the Model
SDK. IDs are preserved, declared assets are installed transactionally, and
the package cache plus module identity are recorded in the marketplace
lockfile. Compatible official packages may be imported forward into the
project's newer model version; local and GitHub imports still require an exact
model-version match. Installing Atlas Core also connects its legacy Sass
variables without replacing project customizations.

Official `pull` is the default. It asks the API for the newest release compatible
with the target MPR, follows the download URL returned by the API, and refuses a release marked
vulnerable unless `--allow-vulnerable` is explicit. The lock records Content ID,
Version ID, visibility, approval and security state; `audit` checks it for known
vulnerabilities and updates. `github:` remains the public fallback, and `import`
accepts a local MPK/ZIP. `login` validates the PAT before storing it outside the
project with mode `0600`.

The PAT is sent only to the exact official hosts `marketplace-api.mendix.com`
and `marketplace.mendix.com`; redirects to any other host do not receive it.
See the [Mendix Marketplace Content API](https://docs.mendix.com/apidocs-mxsdk/apidocs/content-api/).

`marketplace dependencies` discovers unresolved qualified module references in
the embedded package MPR, resolves them recursively through the official API,
downloads each candidate, and accepts it only when the MPK itself proves the
requested module identity. Host-owned project modules satisfy references
without being mislabeled as Marketplace packages. The command previews by
default; `--apply` requires a complete safe graph and installs leaf-first with
rollback, while `--apply-resolved` is the explicit opt-in for a verified partial
graph and still returns a blocked status for unresolved identities.

Authenticated acceptance on August 4, 2026 imported Kafka 2.12.0 (Content ID
105878) and resolved its official dependency graph on both 10.24.0.73019 and
11.12.1. Both graphs imported DataWidgets 3.11.3 with Content ID 116540 and
Version ID `e7b6d703-8e47-42f4-bb92-934e3601e71b`. The final authenticated
Combo box is the independent official Widget/clientModule component 219304,
version 2.9.0, Version ID `dce845f4-d051-4161-847c-016c01703caa`. Its install
backs up and replaces the older 2.6.x Combo asset brought by Atlas Core
(Content ID 117187); Atlas is the prior asset owner, not the Combo component.
The 11.12 graph also includes Library Logging 1.13.0, Encryption 11.1.1,
Mx Model Reflection 9.1.0, and Mendix Feedback Module 5.0.0 (Content ID
205506). The API name index does not expose `FeedbackModule`, so MXRB uses the
official component ID only as a discovery hint and still verifies the
downloaded MPK name before accepting it.

Both generations now pass the complete frontend acceptance gate with zero
source and rebuilt preflight findings, structural equivalence, exact asset and
Marketplace provenance, and zero MxBuild errors. The Ruby export/rebuild
preserves the Marketplace lock, cached MPKs, originals, declared assets, and
their checksums, so the rebuilt project retains package provenance instead of
merely retaining widget bytes. MxBuild remains external validation only, never
an MXRB implementation dependency.

Official `update` and `remove` are safe previews unless `--apply` is explicit.
Before mutation, MXRB checks the locked module and unit count against the cached
package, scans every unit outside the module for references to IDs that would
disappear, and refuses changed or missing package assets. An update must retain
the module ID and any externally referenced unit IDs. Apply snapshots the MPR,
v2 `mprcontents`, lock, caches, declared assets, and Atlas variables file; any
failure restores that complete boundary. Shared assets are never removed while
another locked package claims them.

## Protocol connector audit

`mxrb protocols` is a read-only audit of the IoT, industrial, and messaging
connectors a project imported from the Marketplace. It never runs a protocol
and never installs anything; it reports the public metadata the model exposes.

```sh
mxrb protocols App.mpr
mxrb protocols App.mpr --json
```

Recognized connectors are listed with their module name, protocol, and
Marketplace component id; unrecognized marketplace modules are listed
separately. Recognition is by verified `AppStoreGuid`, so a module whose GUID
is not confirmed from a real fixture or official metadata is reported as
unrecognized rather than guessed.

This protocol registry is a third catalog, distinct from the reusable Ruby
modules of `mxrb module` and the official packages of `mxrb marketplace`.

Verified public component ids currently cover MQTT, OPC-UA, Kafka, AMQP and
WebSocket. Authenticated Content API queries and the official catalog search
still provide no Modbus component, so it remains unregistered until an official
component or real MPR fixture proves its identity. Public ids support planning;
recognition inside an MPR still requires a verified `AppStoreGuid`.

The Ruby builder can declare an installation request without writing an empty
module or invented GUID:

```ruby
builder.connector :kafka, version: "2.12.0"
plans = builder.connector_plans(adapter: Mxrb::Protocols.adapter(installer:, api:))
plans.each { puts _1.changes }
plans.each(&:apply!) # explicit authenticated Marketplace operation
```

`connector_plans` is preview-only without the adapter. A regular `build!` also
fails closed while connector declarations are pending; connector content must
be installed into a real MPR through the official Marketplace adapter first.
Marketplace `Module` and `Service` entries may be resolved, while the downloaded
MPK independently has to pass the module-package boundary checks.
