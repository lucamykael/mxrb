# OQL, SQL views, and the local database

MXRB exposes OQL only when the native model contains it. It discovers OQL
dataset sources and view-entity queries; an app without OQL returns an empty
collection and does not gain synthetic query documents.

## Static inspection

```ruby
Mxrb.open("Shop.mpr") do |project|
  next unless project.oql?

  project.oql_queries.each do |query|
    puts query.qualified_name
    puts query.oql
    puts query.parameters
  end

  project.oql_sql_views(dialect: :postgresql).each do |view|
    puts view.sql if view.supported?
    warn view.warnings.join("\n")
  end
end
```

The CLI provides the same typed result:

```sh
bundle exec mxrb oql Shop.mpr
bundle exec mxrb oql Shop.mpr --dialect ansi
bundle exec mxrb oql Shop.mpr --dialect sql_server --json
```

The SQL view is deliberately read-only. Parameters such as `$Customer` become
named binds such as `:Customer`; values are never interpolated. String literals
and comments remain opaque. Multiple statements and OQL bulk writes are
rejected.

Generated SQL has `logical` confidence. PostgreSQL and SQL Server views use the
conventional `module$entity` table shape, while ANSI keeps `Module.Entity`.
Always verify physical table and column names against the database created by
the exact Mendix Runtime. Association-path joins are reported as unsupported
until Runtime storage metadata can prove the correct join.

## Materialized local PostgreSQL

An MPR contains the application model, not an application-data snapshot. The
Mendix Runtime owns the database schema and synchronizes it from the model.
MXRB can build the exact portable Runtime, start an isolated PostgreSQL, let
the Runtime perform that synchronization, and expose SQL access:

```sh
bundle exec mxrb db up Shop.mpr
bundle exec mxrb db status Shop.mpr
bundle exec mxrb db sql Shop.mpr \
  'SELECT * FROM "sales$order" LIMIT 20'
bundle exec mxrb db shell Shop.mpr
```

After changing the MPR, rebuild and synchronize while retaining the data:

```sh
bundle exec mxrb db sync Shop.mpr
bundle exec mxrb db down Shop.mpr
```

`db down` stops the containers but preserves the PostgreSQL volume. A later
`db up` reuses both the package cache and the data. The host port defaults to
`127.0.0.1:55432` and can be changed with `--port`.

Permanent cleanup is intentionally explicit:

```sh
bundle exec mxrb db destroy Shop.mpr --yes
```

It removes only resources carrying the matching MXRB ownership label.

## Security boundary

- PostgreSQL is bound only to loopback.
- Each absolute MPR path receives separate containers, network, volume, and
  state.
- Random credentials live under the user's XDG state directory with mode
  `0600`, outside the project repository.
- `db sql`, `db shell`, and `db url` use `mxrb_reader`, whose transactions and
  role default are read-only.
- `--write` explicitly selects the Runtime owner role. Direct writes can break
  Mendix invariants and should be exceptional.
- MXRB never connects this workflow to an existing remote database.

The exact Mendix toolchain and Docker daemon must be available. Schema
synchronization can change or reject existing data when the model changes, so
back up any valuable local volume before risky model migrations.

See the official Mendix documentation for
[OQL](https://docs.mendix.com/refguide/oql/),
[data storage](https://docs.mendix.com/refguide/data-storage/), and
[Runtime database settings](https://docs.mendix.com/refguide/custom-settings/).
