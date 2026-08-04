# Nativer Compiler, Runtime und MDA-Format

Die funktionale MXRB-Pipeline führt weder `mx`, `mxbuild`, `mxcli`, Studio Pro
noch das Model SDK aus. Diese Werkzeuge können externe Kompatibilitätsprüfungen
bleiben, sind aber keine Build-, Datenbank- oder Funktionstest-Abhängigkeiten.

## Build von null

`DeploymentMaterializer` erzeugt ein fehlendes `deployment/` aus den Templates
der installierten Version und durchläuft 12 Stufen: Sicherheit, Konstanten,
Domänenmodell, Artefakte, Übersetzungen, Systemtexte, Systemwarteschlangen,
Clientmodell, Actions, Settings, Microflows und Projekt-/Modulindex. Metadaten,
Abhängigkeiten und ein Runtime-kompatibel geordnetes BSON-`model.mdp` werden
ebenfalls erzeugt.

Der Bootstrap besitzt auditierte Seeds und Kataloge für 6.10.8, 7.5.0,
7.17.0, 9.6.1.29396, 10.24.0.73019 und 11.12.1. Die Familien 6.x, 7.x, 9.x, 10.x und 11.x wählen
einen kompatiblen Compiler-Seed; 5.x und 8.x schlagen ohne auditierten
Seed geschlossen fehl. Die Familie gilt nur für das Compiler-Schema. Die
Runtime muss exakt zum Patch des MPR passen.

`ProjectJarBuilder` findet das JDK über `MXRB_JAVA_HOME`, `JAVA_HOME`, asdf oder
mise, kompiliert `javasource/**/*.java` gegen Runtime- und Projektbibliotheken
und schreibt ein deterministisches OSGi-`project.jar`. Für VetClinic wurden 183
Quelldateien zu 249 Klassen kompiliert.

`WebBundleBuilder` wählt Dojo für 6/7, Dojo mit React-Wrapper für 9, den im
Projekt gewählten klassischen oder optimierten Client für 10 und React für 11.
Der React-Pfad erzeugt Entry-/Seitenmodule, entpackt `.mpk` und ruft direkt
Node/Rollup für 10 oder Node/Rspack für 11 auf. Data Grid 2 wird für den Teilumfang aus XPath-Datenquelle
und Attributspalten kompiliert, einschließlich `operations.json`, Datenquelle
und Attributtypen. Noch nicht übersetzte Typen oder Eigenschaftskombinationen
erhalten einen DOM-Fallback in `web/mxrb-pages.json`; das VetClinic-Manifest ist
leer.

Der React-Compiler materialisiert außerdem Container, Texte und Überschriften,
responsive Grids/Spalten sowie Buttons zum Öffnen und Erzeugen. Der Bootstrap
bindet `theme.compiled.css`, das Manifest und Assets aus
`themesource/*/public` ein; eine Homepage mit `LayoutGrid` bleibt nicht leer.
Ruby-Inhalte lassen sich so ergänzen:

Parametergestützte `DataView`-Formulare rendern nun editierbare `TextBox`-Felder
sowie Save/Cancel-Aktionen. Create übergibt die GUID des neuen Objekts über
`openForm2`; Commit-/Rollback-Operationen werden mit den Projektbenutzerrollen
registriert, die aus den erlaubten Modulrollen der Seite abgeleitet werden.
Damit bleibt die Runtime-Autorisierung erhalten und wird nicht umgangen.

Layouts, Platzhalter, Scrollbereiche, Sidebars, Header, Navigationsmenüs,
Snippets, DataViews, ListViews, Formularelemente, Bilder, Combo Boxes, Gallery,
Data Grid 2 und schemagestützte Pluggable Widgets werden über die nativen
React-Client-Verträge kompiliert. Seiten-, Menü- und Widget-Aktionen decken
Navigation, Microflows, Nanoflows, Objektlebenszyklus, Links und Sign-out ab.
Nanoflow-Programme unterstützen außerdem Entscheidungen, Fehlerbehandlung,
JavaScript-Aktionen und serverseitige Microflow-/Commit-
Operationen, sofern der Modellvertrag sicher abgebildet werden kann.

Der React-Pfad kompiliert außerdem die offizielle Gallery mit XPath- und
Microflow-Listenquellen, Template-Inhalten, Auswahl und formatierten dynamischen
Attributen. Nanoflow-Quellen und -Aktionen verwenden die Mendix-Verträge
`NanoflowObjectListProperty`, `NanoflowObjectProperty` und `ActionProperty`.
MXRB erzeugt echte Clientprogramme `{ name, instructions }` für auditierten
Graph-Kontrollfluss, Returns, Variablen, Objekte, Nanoflow-/Microflow-Aufrufe,
JavaScript-, Seiten-, Nachrichten-, Validierungs- und Commit-Aktionen. Fehlende
Flows, unsichere Parameterabbildungen und nicht übersetzte Clientinstruktionen
schlagen geschlossen fehl und bleiben Befunde im Support-Manifest.

In lokalen Runtime-Sitzungen im Developer-Modus versioniert mxrb außerdem
dynamische Seitenimporte, versieht den korrigierten React-Client-Chunk mit
einem Inhalts-Hash und gibt dem Rspack-Selbstimport dasselbe Cache-Token wie
dem Entry-Point. Dadurch können langlebige statische Mendix-Antworten nach
einem nativen Rebuild keine veraltete leere Seite wiederherstellen. Die erzeugte
Shell stellt außerdem einen begrenzten `openForm`-Adapter über `openForm2`
bereit; alte Handler im Cache navigieren damit, statt still ohne Request zu enden.

```ruby
Mxrb.define("App.mpr") do
  mendix_version "11.12.1"
  self.module(:App) do
    layout :Shell
    page(:Home) do
      layout "App.Shell"
      title "Meine Anwendung"
      container(:main, class_name: "container") do
        text :welcome, caption: "Mit mxrb erzeugter Inhalt"
      end
    end
  end
end
```

Bestehende Projekte können exportiert, in der DSL geändert und neu erzeugt
werden. Nicht unterstützte Widgets bleiben im Support-Manifest sichtbar.

Vor einem nativen Build kann das gesamte MPR mit dem für seine Mendix-Version
gewählten Renderer geprüft werden:

```bash
mxrb preflight App.mpr
mxrb preflight App.mpr --json
```

Der Nur-Lese-Befehl liefert bei nicht unterstützten Versionen oder
Client-Features einen Fehlerstatus. Mendix 11 wird über den React-Compiler
geprüft; 6/7/9 verwenden dieselbe Legacy-Dojo-Prüfung wie `WebBundleBuilder`.

Der Dojo-Pfad kompiliert Data Grid 1 mit Datenbank-, XPath- und
Microflow-Quellen sowie auditierten Such-, Sortier-, Paging-, Auswahl- und
Button-Verträgen. Alle anderen sichtbaren Widgets werden pro Seite in
`web/mxrb-legacy-pages.json` erfasst und nicht als gerendert ausgewiesen.

## MDA und portables Paket

```bash
mxrb pack App.mpr --output build/App.mda
mxrb mda inspect build/App.mda
mxrb portable App.mpr --output build/runtime.zip
```

MDA und portables ZIP sind deterministisch. Das portable Paket kombiniert das
native Deployment mit der passenden installierten Runtime, Konfiguration,
Konstanten und Skripten. Arbeitsverzeichnisse wie `data`, `log`, `run`, `build`
und `.gradle` werden nicht in das MDA aufgenommen.

## Regressionsnachweis

```bash
script/runtime_boot_regression App.mpr /fehlendes/deployment \
  ~/.local/share/mendix/11.12.1
```

Der Test erzeugt ein temporäres Deployment, kompiliert Java und Web, paketiert,
startet die Runtime und verlangt HTTP 200 für `/`, `dist/index.js` und jedes
Seitenbundle. Ein sauberes Herunterfahren ist ebenfalls erforderlich. Protokoll
und SHA-256 stehen in `tmp/runtime-boot-evidence.log`. Wenn Chromium installiert
ist, importiert der Test alle Module und instanziiert Factorys ohne
Sitzungsbedarf. Das Data-Grid-Bundle wird importiert und ausgewertet; seine
Factory liest die Clientsitzung und benötigt daher einen authentifizierten Test.

Am 1. August 2026 startete VetClinic 11.12.1 ohne vorhandenes Deployment,
führte 675 Datenbanksynchronisierungen aus, initialisierte die
`System`-Warteschlangen, plante `VetClinic.Cleanup`, lieferte 200 für alle vier
Seitenbundles und fuhr sauber herunter. Danach bestand der Funktionstest
`ACT Create Animal`.

## Explizite Grenzen

- alle 12 Stufen und saubere Web-Generierung sind für 6.10.8, 7.5.0, 7.17.0,
  9.6.1.29396, 10.24.0.73019 und 11.12.1 validiert;
- ein exakter nativer Boot ist für 10.24.0.73019 und 11.12.1 belegt. Die installierten
  6/7/9-Distributionen enthalten exakte Runtime-Bundles, aber keinen
  kompatiblen Launcher; `db up` schlägt geschlossen fehl, statt den Java-21-Launcher
  aus Version 11 einzusetzen;
- Data Grid 1 ist abgedeckt, andere Dojo-Widgets bleiben explizite
  Manifestbefunde;
- der optimierte Mendix-10-React/Rollup-Pfad ist durch eine neu erstellte
  Anwendung belegt; der Mendix-11-React-Pfad besitzt saubere Preflights und vollständige
  Rspack-Builds für LearnNow, MyFirstModule, SLATaskApp, Sudoku und VetClinic.
  Diese Fixture-Matrix belegt auditierte Verträge, keine universelle Kompatibilität;
- native Web-Bundles werden erzeugt; React Native verwendet weiterhin
  bestehende Versions-Template- und Projektassets;
- `mx` und `mxbuild` sind niemals Fallbacks. Nicht unterstützte Eingaben führen
  zu einem klaren Compilerfehler oder einem Eintrag im Support-Manifest.
