# Projekte erstellen und bearbeiten

[Português](../pt-BR/writing.md) · [English](../en-US/writing.md) · **Deutsch**

`mxrb generate` wertet Ruby aus und erstellt oder aktualisiert ein MPR
idempotent anhand stabiler Mendix-Namen.

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
microflow "erstellt Bestellung", call: "Sales.ACT_CreateOrder"
```

`mxrb test App.mpr functional_test.rb --docker` führt Check, Build und Runtime
in wegwerfbaren Containern aus. JUnit und MDL sind nicht nötig; das Original-MPR
wird nie verändert.

## Native Baseline

Der Export schreibt `.mxrb/native_units.json`. Nicht typisierte Units bleiben
vollständig erhalten. `body_fingerprint` verwendet unveränderte native Graphen
exakt wieder und regeneriert sie nach Ruby-Änderungen.

## Seiten, Navigation, Security und MPR v2

Core-Widgets haben kompakte Methoden; importierte Seiten bieten zusätzlich
`deep_structure({...})`. Menüs und Security sind bearbeitbar. Bei MPR v2
erzeugt MXRB automatisch `mprcontents/*.mxunit`.

## Semantische Werkzeuge

CLI-Befehle: `refs`, `callers`, `callees`, `impact`, `rename`, `lint`,
`report`, `diff`, `find`, `describe` und `tree`. Umbenennungen schreiben erst
mit `--apply`.
