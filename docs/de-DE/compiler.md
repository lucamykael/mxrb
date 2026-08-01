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
7.17.0, 9.6.1.29396 und 11.12.1. Die Familien 6.x, 7.x, 9.x und 11.x wählen
einen kompatiblen Compiler-Seed; 5.x, 8.x und 10.x schlagen ohne auditierten
Seed geschlossen fehl. Die Familie gilt nur für das Compiler-Schema. Die
Runtime muss exakt zum Patch des MPR passen.

`ProjectJarBuilder` findet das JDK über `MXRB_JAVA_HOME`, `JAVA_HOME`, asdf oder
mise, kompiliert `javasource/**/*.java` gegen Runtime- und Projektbibliotheken
und schreibt ein deterministisches OSGi-`project.jar`. Für VetClinic wurden 183
Quelldateien zu 249 Klassen kompiliert.

`WebBundleBuilder` wählt Dojo für 6/7, Dojo mit React-Wrapper für 9 und React
für 11. Der React-Pfad erzeugt Entry-/Seitenmodule, entpackt `.mpk` und ruft
Node/Rspack der Version direkt auf. Data Grid 2 wird für den Teilumfang aus XPath-Datenquelle
und Attributspalten kompiliert, einschließlich `operations.json`, Datenquelle
und Attributtypen. Noch nicht übersetzte Typen oder Eigenschaftskombinationen
erhalten einen DOM-Fallback in `web/mxrb-pages.json`; das VetClinic-Manifest ist
leer.

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
  9.6.1.29396 und 11.12.1 validiert;
- ein exakter nativer Boot ist für 11.12.1 belegt. Die installierten
  6/7/9-Distributionen enthalten exakte Runtime-Bundles, aber keinen
  PAD/Launcher; `db up` schlägt geschlossen fehl, statt den Java-21-Launcher
  aus Version 11 einzusetzen;
- Data Grid 1 ist abgedeckt, andere Dojo-Widgets bleiben explizite
  Manifestbefunde;
- Data Grid 2 ist für XPath-Datenquellen und Attributspalten abgedeckt; andere
  Widgets und Eigenschaftskombinationen verwenden den erfassten Fallback;
- native Web-Bundles werden erzeugt; React Native verwendet weiterhin
  bestehende Versions-Template- und Projektassets;
- `mx` und `mxbuild` sind niemals Fallbacks. Nicht unterstützte Eingaben führen
  zu einem klaren Compilerfehler oder einem Eintrag im Support-Manifest.
