# Projekte erstellen und bearbeiten

[Português](../pt-BR/writing.md) · [English](../en-US/writing.md) · **Deutsch**

`mxrb generate` wertet Ruby aus und erstellt oder aktualisiert ein MPR
idempotent anhand stabiler Mendix-Namen.

Ein leeres Verzeichnis kann direkt initialisiert werden:

```sh
mxrb init vet_clinic
cd vet_clinic
bundle install
bundle exec mxrb generate project.rb
bundle exec mxrb validate VetClinic.mpr
```

`init` akzeptiert snake_case oder PascalCase und erstellt `Gemfile`,
`project.rb` sowie das Hauptmodul unter `modules/VetClinic`. Das Scaffold
enthält nur Anwendungscode: `System` ist im Runtime implizit, Administration
und Atlas sind Marketplace-Module. Bei einem vorhandenen Verzeichnis bricht
der Befehl ohne Änderungen ab.

Ein weiteres Anwendungsmodul wird im Projektstamm so hinzugefügt:

```sh
mxrb module new appointments
```

Der Befehl erstellt `modules/Appointments`, verwendet dasselbe Domain- und
Application-Scaffold und bindet dessen `module.rb` in `project.rb` ein. Wenn
das Modul bereits existiert oder die Projektdatei nicht sicher aktualisiert
werden kann, wird der Vorgang atomar abgebrochen. Außerhalb des Projektstamms
kann `--target DIR` verwendet werden.

Artefakt-, Präsentations-, Infrastruktur-, Test-, Design- und CI-Generatoren
sind im [Scaffold-Katalog](scaffolds.md) aufgeführt. Für Entitäten gilt die
vollständige [Entitäten-DSL](entity-dsl.md).

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"
  self.module :Sales do
    entity :Order do
      string :Number, documentation: "Stabile Bestellnummer"
      decimal :Total, default: 0
    end
  end
end
```

```sh
bundle exec mxrb generate shop.rb
bundle exec mxrb validate Shop.mpr
bundle exec mxrb export Shop.mpr exported-shop
bundle exec mxrb compare original.mpr rebuilt.mpr
```

## Modellbewertungen und Funktionstests

Bewertungen sind Ruby mit Checks wie `artifact`, `no_call_cycles` und eigenen
Blöcken. Funktionstests verwenden ebenfalls Ruby:

```ruby
microflow "erstellt Bestellung",
          call: "Sales.ACT_CreateOrder",
          before: { call: "Sales.TEST_Prepare" },
          after: { call: "Sales.TEST_Cleanup" },
          expect: {
            return: "true",
            count: { entity: "Sales.Order", xpath: "[Status = 'Open']", equals: 1 }
          }
```

`mxrb test App.mpr functional_test.rb --docker` führt Check, Build und Runtime
in wegwerfbaren Containern aus. JUnit und MDL sind nicht nötig; das Original-MPR
wird nie verändert.
`--json ergebnis.json` und `--junit ergebnis.xml` erzeugen CI-Berichte. JUnit
ist hier nur das XML-Austauschformat; MXRB schreibt es direkt in Ruby und
installiert oder startet kein Java-JUnit-Framework.

## Native Baseline

Der Export schreibt `.mxrb/native_units.json` als verlustfreie Baseline und
`.mxrb/native_units.rb` mit jedem BSON-Payload als bearbeitbaren Ruby-Hash.
`native_unit`, `deep_structure` und `bson_binary` machen auch Bilder,
Konstanten, Datensätze, Dienste, Einstellungen, Vorlagen und neue Mendix-Typen
direkt bearbeitbar. Ruby-Änderungen überlagern die Baseline vor den typisierten
Writes. `body_fingerprint` verwendet unveränderte native Graphen exakt wieder
und regeneriert sie nach Ruby-Änderungen.

## Ruby-Modul-Marketplace

```sh
mxrb module search
mxrb module search security
mxrb module add shared-kernel
mxrb module add ./lokales-paket --target ./exportiertes-projekt
```

JSON-Kataloge kommen aus der Gem, von einem lokalen Pfad oder über HTTPS mit
`--registry`. Pakete besitzen `mxrb-module.json` und können eingebaut, lokal
oder Git-basiert sein. Die Installation nutzt Staging, lehnt unsichere Pfade ab
und schreibt Version, Quelle, Ref und SHA-256 nach
`.mxrb/modules.lock.json`.

## Seiten, Navigation, Security und MPR v2

Core-Widgets haben kompakte Methoden; importierte Seiten bieten zusätzlich
`deep_structure({...})`. Menüs und Security sind bearbeitbar. Bei MPR v2
erzeugt MXRB automatisch `mprcontents/*.mxunit`.

## Semantische Werkzeuge

CLI-Befehle: `refs`, `callers`, `callees`, `impact`, `rename`, `remove`,
`move`, `lint`, `report`, `diff`, `find`, `describe` und `tree`. Das eingebaute
Lint prüft Zugriffsregeln persistenter Entitäten, Rollen von Seiten/Flows,
Dokumentation öffentlicher Verträge, Navigationsziele und doppelte
Modulrollenzuordnungen. `mxrb cache status|warm|clear app.mpr` liefert
Cache-Metriken und Wartung.
Refactorings schreiben erst mit `--apply`; Verschiebungen bleiben im selben
Modul und verhindern Ordnerzyklen.

Bei `readonly: false` speichert der erste Aufbau einen kompakten,
fingerprint-basierten semantischen Index im MPR. Spätere Öffnungen verwenden
ihn nur, solange Inhalte und Containment unverändert sind. Schreibgeschützte
Projekte können einen vorhandenen Cache lesen, erstellen ihn aber nicht.
