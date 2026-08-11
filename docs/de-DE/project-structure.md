# Struktur des exportierten Projekts

[Português](../pt-BR/project-structure.md) · [English](../en-US/project-structure.md) · **Deutsch**

`mxrb export` bietet zwei explizite Modi. `--mode mendix` ist der Standard und
behält den geschichteten Mendix-DSL-Baum. `--mode ruby` erzeugt eine
konventionelle ausführbare Ruby-Anwendung mit React + Vite.

## Mendix-Modus

```sh
bundle exec mxrb export App.mpr app-source --mode mendix
```

Dieser Baum trennt anwendungsweite Richtlinien, Modulverhalten, erhaltene
native Units und Assets:

```text
project.rb
.mxrb/{native_units.json,native_units.rb,assets.json}
app/{security,navigation,design_system}/
modules/Modulname/{domain,application,presentation,infrastructure,security}/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` orchestriert das Laden. Module enthalten das Verhalten. Das
native Manifest erhält Strukturen ohne kompakte DSL; das Asset-Manifest
speichert relative Pfade, Größen und SHA-256-Prüfsummen.

Absolute Pfade, `..`-Traversal, fehlende Dateien und abweichende Prüfsummen
schlagen beim Wiederaufbau sicher fehl. Nur Manifest-Einträge werden geschrieben.

Die Struktur unterstützt Ruby zu einem neuen Mendix-Projekt, Ruby auf einem
exportierten Baseline, Mendix zu bearbeitbarem Ruby und den strukturell
gleichwertigen Mendix → Ruby → Mendix Round-trip.

## Ruby-Modus

Der Ruby-Modus kann auch ohne vorhandenes Mendix-Projekt beginnen:

```sh
bundle exec mxrb init CustomerPortal --mode ruby
cd CustomerPortal
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

Der Befehl erzeugt direkt die konventionelle Anwendung mit `app/models`,
`app/dtos`, `app/services`, `app/pages` und React + Vite. Eine reversible
Mendix-Basis bleibt unter `.mxrb` isoliert und bestimmt nicht die bearbeitbare
Quellstruktur. Das aktuelle Projekt wird so als MPR materialisiert:

```sh
bundle exec mxrb generate project.rb build/CustomerPortal.mpr
```

Neue Ruby-Models werden zu Entitäten, DTOs zu nicht-persistenten Entitäten und
bidirektionale Deklarationen werden in das MPR synchronisiert. Ruby- oder
React-Code ohne native Mendix-Repräsentation bleibt mit Prüfsumme eingebettet
und erscheint beim nächsten Export unverändert. Nicht darstellbare strukturelle
Änderungen führen explizit zum Fehler, statt unbemerkt teilweise konvertiert zu
werden.

Ein vorhandenes MPR wird so konvertiert:

```sh
bundle exec mxrb export App.mpr app-ruby --mode ruby
```

```text
app/
  models/
  dtos/
  services/
  pages/
config/application.rb
frontend/
  package.json
  vite.config.js
  src/{main.jsx,App.jsx,app.css}
project.rb
.mxrb/
  ruby-app.json
  runtime/App.mpr
  mendix/
```

Persistente Entitäten werden Records. Nicht persistente Entitäten werden
DTO-Klassen und verwenden immer das Suffix `_dto.rb`, wodurch mehrdeutige
`_2.rb`-Namen entfallen. Services sind normale Ruby-Klassen und delegieren
anfangs an den nativen Pure-Ruby-Interpreter. Pages stellen dem React-Frontend
native Metadaten bereit.

Nach der einmaligen Installation der Ruby- und Frontend-Abhängigkeiten startet
ein einziger Befehl beide Prozesse:

```sh
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

`mxrb run` überwacht die Ruby-JSON-API auf Loopback und den Vite-Server. Vite
leitet `/api` an Ruby weiter. `--server-port` legt den Backend-Port fest und
`--client-port` den Frontend-Port. `--no-frontend` startet nur die API. Die
bisherigen Namen `--api-port` und `--port` bleiben kompatible Aliase.
Die globale Option `--no-progress` ist optional und blendet nur Fortschritt aus.

Zwei optionale Stacks ergänzen vertraute Ruby-Konventionen, ohne den
Standard-Ruby-Modus zu ändern:

```sh
bundle exec mxrb init ServiceDesk --mode ruby --flymetothemoon
bundle exec mxrb export App.mpr app-rails --mode ruby --onrails
```

`--flymetothemoon` ergänzt Sinatra, Puma, ActiveRecord, Rake und RSpec.
`--onrails` ergänzt Rails, Puma, ActiveRecord und RSpec. Beide behalten React +
Vite als integriertes Anwendungs-Frontend und verwenden weiterhin
`mxrb run .`. ActiveRecord-Migrationen besitzen nur Ruby-Tabellen; für das
Mendix-Domain-Model und seine Round-trips bleibt das MXRB-Manifest maßgeblich.

## Domain-Model-Diagramm im Browser

Domain Models eines oder mehrerer Mendix-Module lassen sich als
DBeaver-inspiriertes ER-Diagramm öffnen:

```sh
bundle exec mxrb diagram-er App.mpr --module Sales
bundle exec mxrb diagram-er App.mpr --module Sales --module Billing \
  --output build/App-layout.mpr
```

In der Seitenleiste lassen sich mehrere Module gleichzeitig auswählen und ihre
modulübergreifenden Assoziationen anzeigen. Die Seite bietet außerdem
Entitätssuche, Drag-and-drop-Positionierung, Zoom, Anpassen, Auto-Anordnung,
Raster, Attributsichtbarkeit, Beziehungsrouting und ziehbare Quell-/Zielanker.
Persistente Entitäten sind blau, DTOs/non-persistent gelb und OQL Views grün.
**Layout im MPR speichern** schreibt Positionen und lokale Anker in native
Mendix-Felder. Modulübergreifende Anker ohne natives BSON-Feld werden als
isolierte visuelle MXRB-Metadaten in derselben sicheren Kopie gespeichert.
Standard ist `App.domain-layout.mpr`; eine vorhandene Ausgabe darf nur mit
`--force` ersetzt werden.

**PNG exportieren** lädt ein hochauflösendes Bild der ausgewählten Module mit
den aktuellen Farben, Attributen und Routen herunter. Der PNG-Export ändert das
MPR nicht; das Layout muss separat gespeichert werden, wenn die Positionen
einen Round-trip überstehen sollen.

Der Vordergrundmodus bleibt verfügbar und belegt das Terminal bis `Ctrl+C`.
Mit dem verwalteten Lifecycle läuft der ER-Editor im Hintergrund; beim Stoppen
bleibt die Layout-Kopie erhalten und das Quell-MPR wird weder bearbeitet noch
entfernt:

```sh
bundle exec mxrb diagram-er up App.mpr --module Sales
bundle exec mxrb diagram-er status App.mpr
bundle exec mxrb diagram-er down App.mpr
bundle exec mxrb diagram-er up App.mpr       # dieselbe Kopie fortsetzen
bundle exec mxrb diagram-er destroy App.mpr --yes
```

`destroy` stoppt den Server und entfernt ausschließlich die von diesem
Lifecycle erzeugte Kopie samt externen Inhalten. Die Steuerung nutzt einen
privaten authentifizierten Loopback-Endpunkt; Zustand und Token liegen in lokal
zugriffsbeschränkten Dateien.

Die Editor-Oberfläche ist in React + TypeScript implementiert und verwendet nur
die APIs des Ruby-Servers. Das Vite-Bundle wird nach `lib/mxrb/web_ui`
kompiliert, in die Gem aufgenommen und lokal ausgeliefert. Node.js ist daher
für die Nutzung des installierten Editors nicht erforderlich, und es wird kein
CDN kontaktiert. Für die UI-Entwicklung werden in `frontend/modeler`
`npm install`, `npm run typecheck` und `npm run build` ausgeführt.

## UML-Diagramme

UML ist eine zusätzliche, vom ER-Editor unabhängige Implementierung. Sie nutzt
Port 4569 und verändert das Domain-Model-Layout nicht. Der Viewer vereint
Klassen-, Microflow-Aktivitäts- und Aufrufsequenzdiagramme mit Mermaid:

```sh
bundle exec mxrb uml App.mpr
bundle exec mxrb uml App.mpr --export=class --module Sales
bundle exec mxrb uml App.mpr --export=activity \
  --microflow=Sales.CreateOrder --format=plantuml
bundle exec mxrb uml App.mpr --export=sequence \
  --root=Sales.CreateOrder --depth=3
bundle exec mxrb uml App.mpr --export=sequence --module=Sales
```

Ohne `--export` läuft der gemeinsame Viewer unter
`http://127.0.0.1:4569`. Textexporte verwenden standardmäßig Mermaid;
PlantUML wird mit `--format=plantuml` gewählt. Sequenzdiagramme akzeptieren
entweder einen tiefenbegrenzten Einstiegspunkt oder alle internen Aufrufe eines
Moduls. Der Viewer verwendet denselben React-+-TypeScript-Workspace; Mermaid ist
lokal gebündelt, damit die Darstellung auch offline funktioniert.

## Versionswechsel und Round-trips

Beide Modi behalten stabile Mendix-IDs und die vollständige native Baseline für
Upgrades, Downgrades und wiederholte Round-trips. Im Ruby-Modus werden
Model-/DTO-Deklarationen zurück in das MPR kompiliert. Ruby-Service-Bodies und
React-Quellen werden mit SHA-256 in einer MXRB-Quelltabelle innerhalb des MPR
gespeichert; ein späterer Export mit `--mode ruby` stellt die exakt bearbeiteten
Dateien wieder her.

Für Konstrukte ohne semantischen Ruby-zu-Mendix-Compiler bleibt das native
Mendix-Verhalten maßgeblich. Das Coverage-Manifest weist diesen Status explizit
aus, statt eine stille Konvertierung zu behaupten. Der erhaltene Ruby-/React-
Quellcode überlebt den Mendix-Round-trip auch ohne direkte Studio-Pro-Darstellung.

[Zurück zum Index](README.md)
