# Schema-Migrationen der Ruby-Runtime

`Mxrb::Runtime::SchemaMigrator` identifiziert Mendix-Entitäten, Attribute und
Assoziationen anhand ihrer Storage-GUID. Wird ein Artefakt bei gleicher GUID
umbenannt, bleiben die physische Tabelle beziehungsweise Spalte und ihre Daten
erhalten.

## Sichere Richtlinie

- Tabellen und optionale Attribute werden automatisch und idempotent angelegt.
- Pflichtattribute werden als `NOT NULL` erzeugt.
- Wird ein vorhandenes Attribut verpflichtend, wird die Tabelle innerhalb
  einer Transaktion neu aufgebaut. Vorhandene `NULL`-Werte verwenden den
  deklarierten Standardwert; ohne Standardwert wird die Migration abgelehnt.
- Ein neues Pflichtattribut in einer befüllten Tabelle benötigt einen
  Standardwert.
- Kompatible Änderungen erhalten Entitäts- und Assoziationsdaten.
- Das Entfernen einer Entität, eines Attributs oder einer Assoziation löst
  standardmäßig `Mxrb::Runtime::UnsafeSchemaMigrationError` aus und verändert
  die Datenbank nicht.
- Nach Prüfung des Plans und einem Backup kann die Bereinigung mit
  `allow_destructive: true` freigegeben werden. Entfernt werden ausschließlich
  in den MXRB-Metadaten registrierte Artefakte; fremde Tabellen werden niemals
  abgeleitet oder gelöscht.

Exportierte Ruby-Anwendungen deaktivieren destruktive Migrationen. Für einen
kontrollierten Lauf nach einem Backup kann im gewählten Umgebungsprofil
`MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=true` gesetzt werden. Jeder andere Wert
bleibt fail-closed.

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

DDL, Datenkopie, Metadaten-Update und freigegebene Bereinigung laufen in einer
gemeinsamen SQLite-Transaktion. Eine Constraint-Verletzung oder ein anderer
Fehler setzt die gesamte Migration zurück.
