# MXRB

[English](README.md) · [Português](README.pt-BR.md) · **Deutsch**

MXRB ist ein Ruby-First-Werkzeug zum Lesen, Schreiben, Exportieren, Validieren
und Testen von Mendix-Projekten (`.mpr`) ohne MDL oder `mxcli`.

## Funktionen

- tiefes Lesen und Schreiben von MPR v1/v2;
- Export in bearbeitbare Ruby-Projekte;
- idempotente Generierung mit Ruby-DSL;
- Erhalt nativer Units ohne kompakte Abstraktion;
- Vergleich, semantischer Diff, Referenzen und Impact-Analyse;
- sichere Umbenennung mit Vorschau;
- Lint und ausführbare Modellbewertungen;
- funktionale Microflow-Tests lokal oder in Docker.
- Suche und Installation wiederverwendbarer Ruby-Module mit SHA-256-Lock.

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
```

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

## Entwicklung

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
```

Die Suite erzwingt 100 % Zeilenabdeckung. Branch-Abdeckung wird separat
ausgewiesen.

Siehe die [vollständige deutsche Dokumentation](docs/de-DE/README.md).

## Lizenz

MIT.
