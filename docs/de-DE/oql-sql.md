# OQL, SQL-Ansicht und lokale Datenbank

MXRB stellt OQL nur bereit, wenn das native Modell tatsächlich OQL enthält.
Erkannt werden OQL-Quellen von Datasets und Abfragen von View Entities. Eine
Anwendung ohne OQL liefert eine leere Sammlung und erhält keine künstlichen
Abfragedokumente.

## Statische Inspektion

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

Die CLI liefert dasselbe typisierte Ergebnis:

```sh
bundle exec mxrb oql Shop.mpr
bundle exec mxrb oql Shop.mpr --dialect ansi
bundle exec mxrb oql Shop.mpr --dialect sql_server --json
```

Die SQL-Ansicht ist strikt schreibgeschützt. Parameter wie `$Customer` werden
zu benannten Bind-Parametern wie `:Customer`; Werte werden nie interpoliert.
Zeichenketten und Kommentare bleiben undurchsichtig. Mehrere Anweisungen und
schreibende OQL-Operationen werden abgelehnt.

Das erzeugte SQL hat die Vertrauensstufe `logical`. PostgreSQL- und
SQL-Server-Ansichten verwenden die übliche Tabellenform `module$entity`, ANSI
behält `Module.Entity` bei. Physische Namen müssen immer mit der Datenbank des
exakten Mendix Runtime geprüft werden. Assoziationspfad-Joins gelten als nicht
unterstützt, solange Runtime-Speichermetadaten den korrekten Join nicht
beweisen können.

## Materialisierte lokale PostgreSQL-Datenbank

Eine MPR enthält das Anwendungsmodell, nicht einen Snapshot der
Anwendungsdaten. Das Mendix Runtime verwaltet das Datenbankschema und
synchronisiert es aus dem Modell. MXRB kann das exakte portable Runtime bauen,
eine isolierte PostgreSQL-Datenbank starten, diese Synchronisierung ausführen
lassen und SQL-Zugriff bereitstellen:

```sh
bundle exec mxrb db up Shop.mpr
bundle exec mxrb db status Shop.mpr
bundle exec mxrb db sql Shop.mpr \
  'SELECT * FROM "sales$order" LIMIT 20'
bundle exec mxrb db shell Shop.mpr
```

Nach einer Änderung der MPR wird unter Beibehaltung der Daten neu gebaut und
synchronisiert:

```sh
bundle exec mxrb db sync Shop.mpr
bundle exec mxrb db down Shop.mpr
```

`db down` stoppt die Container, bewahrt aber das PostgreSQL-Volume. Ein
späteres `db up` verwendet Paket-Cache und Daten erneut. Der Standard-Port ist
`127.0.0.1:55432` und kann mit `--port` geändert werden.

Die dauerhafte Bereinigung ist absichtlich explizit:

```sh
bundle exec mxrb db destroy Shop.mpr --yes
```

Entfernt werden nur Ressourcen mit dem passenden MXRB-Eigentümer-Label.

## Sicherheitsgrenze

- PostgreSQL wird ausschließlich an die Loopback-Schnittstelle gebunden.
- Jeder absolute MPR-Pfad erhält eigene Container, Netzwerk, Volume und
  Zustandsdaten.
- Zufällige Zugangsdaten liegen außerhalb des Repositorys im
  XDG-Zustandsverzeichnis und haben den Modus `0600`.
- `db sql`, `db shell` und `db url` verwenden `mxrb_reader`; Rolle und
  Transaktionen sind standardmäßig schreibgeschützt.
- `--write` wählt ausdrücklich die Eigentümerrolle des Runtime. Direkte
  Schreibzugriffe können Mendix-Invarianten verletzen und sollten Ausnahmen
  bleiben.
- MXRB verbindet diesen Ablauf nie mit einer vorhandenen entfernten Datenbank.

Das exakte Mendix-Toolchain und der Docker-Daemon müssen verfügbar sein. Eine
Schemasynchronisierung kann bei Modelländerungen vorhandene Daten ändern oder
ablehnen. Wertvolle lokale Volumes sollten vor riskanten Migrationen gesichert
werden.

Siehe die offizielle Mendix-Dokumentation zu
[OQL](https://docs.mendix.com/refguide/oql/),
[Datenspeicherung](https://docs.mendix.com/refguide/data-storage/) und
[Runtime-Datenbankeinstellungen](https://docs.mendix.com/refguide/custom-settings/).
