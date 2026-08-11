# Ruby runtime schema migrations

`Mxrb::Runtime::SchemaMigrator` identifies Mendix entities, attributes, and
associations by storage GUID. Renaming an artifact while preserving its GUID
keeps the physical table or column and its data.

## Safe policy

- Creating tables and adding optional attributes is automatic and idempotent.
- Required attributes are emitted as `NOT NULL`.
- Making an existing attribute required rebuilds the table transactionally.
  Existing `NULL` values use the declared default; without a default, the
  migration is rejected.
- Adding a required attribute to a populated table requires a default.
- Compatible changes preserve entity and association rows.
- Removing an entity, attribute, or association raises
  `Mxrb::Runtime::UnsafeSchemaMigrationError` by default and leaves the
  database unchanged.
- After reviewing the plan and taking a backup, destructive cleanup can be
  enabled with `allow_destructive: true`. Only artifacts recorded in MXRB
  metadata are removed; unrelated tables are never inferred or deleted.

Exported Ruby applications keep destructive migration disabled. For a
controlled run after backup, set
`MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=true` in the selected environment profile.
Every other value remains fail-closed.

```ruby
database = SQLite3::Database.new('runtime.sqlite3')
migrator = Mxrb::Runtime::SchemaMigrator.new(
  project,
  database: database,
  allow_destructive: true
)
result = migrator.migrate!
puts migrator.migration_plan.changes
```

DDL, data copying, metadata updates, and authorized cleanup share one SQLite
transaction. Any constraint violation or other failure rolls back the complete
migration.
