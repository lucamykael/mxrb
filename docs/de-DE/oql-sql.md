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

## Dialektabhängige Analyse

`Oql::Analyzer` erkennt Kosten- und Portabilitätsmuster im Originaltext,
bewahrt das auslösende Fragment für Hervorhebungen und liefert konkrete
Alternativen für PostgreSQL, SQL Server und ANSI:

```ruby
report = Mxrb::Oql::Analyzer.new(dialect: :postgresql)
                            .analyze_source("SELECT * FROM Sales.Order")
report.findings.each { puts "#{_1.rule}: #{_1.suggestions[:postgresql]}" }

reports = Mxrb.open("Shop.mpr") { _1.oql_analysis(dialect: :postgresql) }
```

Regeln erfassen führende und beidseitige Wildcards, Präfixsuchen,
`LOWER`/`UPPER`/`CAST` in `WHERE`, kartesische Produkte und `SELECT *`.
Findings sind `hint`, `warning` oder `error`; `clean?` bedeutet keine Fehler.

Die CLI verarbeitet natives OQL sowie Ad-hoc-Quellen in OQL und SQL:

```sh
bundle exec mxrb analyze Shop.mpr --dialect postgresql
bundle exec mxrb analyze --oql "SELECT * FROM Sales.Order"
bundle exec mxrb analyze --sql "SELECT * FROM sales$order" --json
```

## Reale Pläne und Datenbank-Performance

Eine statische Analyse kann nicht beweisen, welchen Pfad der Optimierer wählt.
Im materialisierten PostgreSQL-Workspace fragt MXRB deshalb auch den realen
Planner im JSON-Format ab und verknüpft Planrelationen mit `pg_indexes`:

```sh
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM \"sales$order\" WHERE status = 'Open'"
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM \"sales$order\" WHERE status = 'Open'" --analyze --json
```

Der Standardmodus verwendet `EXPLAIN` und führt die Abfrage nicht aus.
`--analyze` ist explizit, weil es `EXPLAIN ANALYZE` verwendet; die Abfrage läuft
mit der schreibgeschützten Rolle und liefert Zeiten und Buffer. Der Bericht
unterscheidet kleine, möglicherweise optimale sequenzielle Scans von großen
Scans. Außerdem meldet er viele verworfene Filterzeilen, abweichende
Kardinalitätsschätzungen, Nested Loops mit hohem Volumen und Sortierungen auf
Festplatte. Vorhandene Indizes dienen als Evidenz; MXRB erfindet ohne
Selektivitäts- und Workload-Daten keine `CREATE INDEX`-Anweisungen.

Auch der kumulative PostgreSQL-Workload kann untersucht werden:

```sh
bundle exec mxrb db workload Shop.mpr --limit 50
bundle exec mxrb db workload Shop.mpr --limit 50 --json
```

Der Workspace aktiviert `pg_stat_statements` und `track_io_timing`. Der Bericht
ordnet Query-Fingerprints nach kumulativem Aufwand und analysiert mittlere
Latenz, Cache-Hits, I/O, temporäre Blöcke und Zeilen pro Aufruf.
Tabellenstatistiken zeigen sequenziellen Scan-Druck; große nicht eindeutige
Indizes ohne beobachtete Scans werden ebenfalls gemeldet. Da diese Werte seit
dem Statistik-Reset kumulativ sind, wird eine Indexentfernung nie ohne Prüfung
des realen Zeitfensters und Workloads empfohlen.

Für ein SQL-Server-Deployment wird die Verbindung explizit mit `sqlcmd`
angegeben:

```sh
export MXRB_SQLSERVER_PASSWORD='geheim'
bundle exec mxrb db explain Shop.mpr \
  "SELECT * FROM dbo.[Order] WHERE Status = 'Open'" \
  --engine sql_server --server db.example:1433 \
  --database Shop --user mxrb_analyst --json
```

Der geschätzte Modus nutzt `SHOWPLAN_XML`; `--analyze` verwendet `STATISTICS
XML` und führt nur ein `SELECT`/`WITH` aus. Der Parser erkennt große Table- und
Clustered-Scans, Nested Loops mit hohem Volumen, tempdb-Spills,
Kardinalitätsabweichungen und Missing-Index-Hinweise. Diese Hinweise bleiben
Optimierer-Hypothesen und werden nicht automatisch als DDL ausgeführt. Das
Passwort wird über `SQLCMDPASSWORD` und nie per argv übertragen. Der Engine-Typ
wird nicht aus der MPR abgeleitet, da er zur Deployment-Konfiguration gehört.

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

Die Zugangsdaten des vorhandenen Runtime-Administrators lassen sich prüfen,
ohne das Passwort standardmäßig auszugeben:

```sh
bundle exec mxrb db credentials Shop.mpr
bundle exec mxrb db credentials Shop.mpr --copy
bundle exec mxrb db credentials Shop.mpr --json
bundle exec mxrb db credentials Shop.mpr --show-password
```

`--copy` übergibt das Passwort per stdin an die Zwischenablage und nie als
Prozessargument. Nur `--show-password` gibt es aus; im JSON bleibt `password`
ohne diese Option `null`. `--copy` und `--show-password` schließen einander
aus. Der Befehl liest nur einen vorhandenen Workspace: Er erzeugt oder rotiert
keine Zugangsdaten und verweist auf `db up`, falls noch kein Zustand existiert.
Dies sind die Zugangsdaten des Mendix-Anwendungsadministrators, getrennt von
den PostgreSQL-Rollen `mxrb_reader` und Runtime-Eigentümer.

Nach einer Änderung der MPR wird unter Beibehaltung der Daten neu gebaut und
synchronisiert:

```sh
bundle exec mxrb db sync Shop.mpr
bundle exec mxrb db down Shop.mpr
```

`db down` stoppt die Container, bewahrt aber das PostgreSQL-Volume. Ein
späteres `db up` verwendet Paket-Cache und Daten erneut. Der Standard-Port ist
`127.0.0.1:55432` und kann mit `--port` geändert werden.

Lokale Werkzeuge können denselben Workspace über JSON HTTP abfragen:

```sh
bundle exec mxrb serve Shop.mpr --port 4567
curl -X POST http://127.0.0.1:4567/query \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT * FROM \"sales$order\" LIMIT 20"}'
```

Der Body akzeptiert genau ein Feld `sql` oder `oql`. Ad-hoc-OQL durchläuft den
sicheren PostgreSQL-Übersetzer; parametrisierte Abfragen und alles außer einer
einzelnen `SELECT`-/`WITH`-Anweisung werden abgelehnt. Antworten enthalten
`rows`, `row_count`, `elapsed_ms`, Warnungen oder einen strukturierten Fehler.
Der Server bindet nur an Loopback, verwendet `mxrb_reader` und bereitet den
Workspace standardmäßig vor; `--no-up` verwendet einen bereits laufenden
Workspace.

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
- `mxrb_reader` erhält im isolierten Workspace `pg_read_all_stats`, damit
  Runtime-Fingerprints korreliert werden können; dies erlaubt keine Datenänderung.
- `--write` wählt ausdrücklich die Eigentümerrolle des Runtime. Direkte
  Schreibzugriffe können Mendix-Invarianten verletzen und sollten Ausnahmen
  bleiben.
- Der PostgreSQL-Workspace zeigt nie auf eine bestehende entfernte Datenbank.
  Die SQL-Server-Plananalyse ist eine separate, explizite Deployment-Verbindung;
  dafür sollte ein Read-only-Login mit SHOWPLAN-Berechtigung verwendet werden.
  Das Passwort bleibt in einer Umgebungsvariable und mutierende Schlüsselwörter,
  auch in schreibenden CTEs, werden abgelehnt.

Das exakte Mendix-Toolchain und der Docker-Daemon müssen verfügbar sein. Für
SQL-Server-Pläne wird zusätzlich `sqlcmd` benötigt. Eine Schemasynchronisierung
kann bei Modelländerungen vorhandene Daten ändern oder
ablehnen. Wertvolle lokale Volumes sollten vor riskanten Migrationen gesichert
werden.

Siehe die offizielle Mendix-Dokumentation zu
[OQL](https://docs.mendix.com/refguide/oql/),
[Datenspeicherung](https://docs.mendix.com/refguide/data-storage/) und
[Runtime-Datenbankeinstellungen](https://docs.mendix.com/refguide/custom-settings/).
