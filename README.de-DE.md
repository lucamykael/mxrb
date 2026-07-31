# MXRB

[English](README.md) · [Português](README.pt-BR.md) · **Deutsch**

MXRB ist ein Ruby-First-Werkzeug zum Lesen, Schreiben, Exportieren, Validieren
und Testen von Mendix-Projekten (`.mpr`) ohne MDL oder `mxcli`.

## Funktionen

- tiefes Lesen und Schreiben von MPR v1/v2;
- Export in bearbeitbare Ruby-Projekte;
- idempotente Generierung mit Ruby-DSL;
- Scaffold für neue Projekte mit PascalCase-Hauptmodul;
- tiefe Ruby-Bearbeitung jeder nativen Unit mit verlustfreier Baseline;
- Vergleich, semantischer Diff, Referenzen und Impact-Analyse;
- sichere Umbenennung mit Vorschau;
- Verschieben eigenständiger Units zwischen Ordnern desselben Moduls;
- Entfernen eigenständiger Units nach Referenz- und Kind-Unit-Prüfung;
- Lint und ausführbare Modellbewertungen;
- Erkennung von nativem OQL und logische SQL-Ansicht nur bei vorhandenem OQL;
- isolierte, durch das Runtime synchronisierte PostgreSQL für direkte SQL-Abfragen;
- Analyse von PostgreSQL-/SQL-Server-Plänen und kumulativem PostgreSQL-Workload;
- funktionale Microflow-Tests lokal oder in Docker.
- Suche und Installation wiederverwendbarer Ruby-Module mit SHA-256-Lock.

Die Matrix bewahrt Mendix-5.21–11.12-Projekte strukturell. Eine exakte native
Mendix-5-Prüfung erfordert weiterhin Windows/Studio Pro und ist eine
ausdrückliche MXRB-Einschränkung; sie gehört nicht zum direkten automatischen
Toolchain-Gate.

## Voraussetzungen

Ruby 4.0+, SQLite3 und für offizielle Gates das exakte Mendix-Toolchain. Lokal
wird kompatibles Java benötigt; Docker stellt JDK und Runtime bereit.

```sh
bundle install
bundle exec mxrb validate App.mpr
bundle exec mxrb export App.mpr app-ruby
bundle exec mxrb compare original.mpr rebuilt.mpr
bundle exec mxrb module search
bundle exec mxrb module add shared-kernel
bundle exec mxrb cache status App.mpr
bundle exec mxrb cache warm App.mpr
bundle exec mxrb cache clear App.mpr
bundle exec mxrb oql App.mpr --dialect postgresql
bundle exec mxrb db up App.mpr
bundle exec mxrb db sql App.mpr 'SELECT * FROM "sales$order" LIMIT 20'
```

Die MPR speichert das Modell, nicht die Anwendungsdaten. `db up` baut das
exakte portable Runtime und lässt es ein isoliertes PostgreSQL-Volume
synchronisieren. Der Zugriff ist auf Loopback beschränkt und verwendet ohne
ausdrückliches `--write` eine schreibgeschützte Rolle. Siehe
[OQL und lokaler SQL-Zugriff](docs/de-DE/oql-sql.md).

## Ruby-DSL

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"
  self.module :Sales do
    entity :Order do
      string :Number, required: true
      decimal :Total, default: 0
    end
  end
end
```

## Bewertungen und Funktionstests

```ruby
artifact "Sales.Order", kind: :entity
no_call_cycles
no_missing_internal_references
```

```ruby
microflow "erstellt Bestellung", call: "Sales.ACT_CreateOrder"
```

```sh
bundle exec mxrb evaluate Shop.mpr evaluation.rb
bundle exec mxrb test Shop.mpr functional_test.rb --docker
```

JUnit und MDL sind nicht erforderlich. Instrumentierung, Paket, Datenbank und
Uploads existieren nur in der wegwerfbaren Kopie; das Original bleibt unverändert.
Assertions prüfen Rückgabewerte und persistierten Zustand über
Entitäts-/XPath-Zählungen.

## Entwicklung

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
bundle exec ruby script/branch_report.rb
bundle exec rubocop
```

Die Suite erzwingt 100 % Zeilen- und Branch-Abdeckung.

Siehe die [vollständige deutsche Dokumentation](docs/de-DE/README.md).

## Lizenz

MIT.
