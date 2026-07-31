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

The official web Marketplace does not expose a complete stable public PAT
download flow. MXRB therefore keeps three capabilities explicit:

```sh
mxrb marketplace search CommunityCommons
mxrb marketplace pull CommunityCommons
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr MyApp.mpr
mxrb marketplace pull CommunityCommons --mpr MyApp.mpr
mxrb marketplace list
mxrb marketplace verify
mxrb marketplace login
```

With `--mpr`, MXRB reads the package's `package.xml` and embedded
`project.mpr`, then imports the complete module unit tree directly through
Ruby/SQLite/BSON. It does not invoke `mx`, `mxcli`, Studio Pro, or the Model
SDK. IDs are preserved, declared assets are installed transactionally, and
the package cache plus module identity are recorded in the marketplace
lockfile. Pure-Ruby imports require package and target model versions to
match.

`pull` resolves public GitHub releases; `import` accepts a previously downloaded
MPK/ZIP. Both extract safely, refuse replacement, and lock source, version, and
SHA-256. `login` stores the PAT outside the project with mode `0600`; it is a
foundation for future authenticated support and is not currently used by
`pull`. Ruby packages remain under the separate `mxrb module search/add` flow.
