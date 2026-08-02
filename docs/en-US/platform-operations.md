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
