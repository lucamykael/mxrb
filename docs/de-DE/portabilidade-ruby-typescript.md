# Echte Portabilität zwischen Ruby, TypeScript und Mendix

## Kalenderausdrücke

Ruby und TypeScript unterstützen Datumserzeugung, Addition/Subtraktion von
Millisekunden bis Jahren, Periodenanfänge und Epoch-Konvertierung in Millisekunden.
Kalenderoperationen haben UTC-Varianten. Ruby verwendet die IANA-Zeitzone des
Sicherheitskontexts; das Frontend verwendet die Browser-Zeitzone oder eine explizite
`timeZone`. Folgeanfragen übernehmen keine Zeitzone vorheriger Benutzer.
Monats-/Jahresoperationen begrenzen den Tag auf das Monatsende; Stunden und kleinere
Einheiten sind Zeitdauern, Kalendertage behalten die lokale Uhrzeit bei DST-Wechseln.

Lokale Tests prüfen New York, Lord Howe und Apia. Die native Matrix ergänzt 16
UTC-Fälle für Original und Round-trip. Lokale Tests allein belegen keine native
Gleichwertigkeit. Lokalisierte Datumsformate und Datumsdifferenzen bleiben separate Verträge.


[Calendar evidence](../evidence/calendar-expressions-2026-10-06.json).

## Dynamische Diagrammreihen — 6. Oktober 2026

Linien- und Säulendiagramme unterstützen dynamische Reihen, gruppiert nach dem
konfigurierten Attribut, mit Quellsortierung und eigener Aggregation pro Gruppe.
Datenänderungen aktualisieren Punkte und ergänzen Gruppen. Typisierte
Ruby-Eigenschaften akzeptieren
`caption("Region {1}", parameters: ["$currentObject/App.Point.Region"])`;
das Frontend wertet Parameter im Datensatz der Reihe aus. Zahlen und gleich
lautende Zeichenketten bleiben unterschiedliche Gruppen.

Geprüft sind einfache Ausdrucks- und Attributparameter. Übersetzungen,
benutzerdefinierte Formatierung und andere Seitenvariablen sind durch diese
Caption-Projektion nicht zertifiziert. Stapelung, Punktaktionen und erweiterte
Plotly-Optionen bleiben offen. Der Windows-Workflow führt `chart-series` sowohl
für das ursprüngliche als auch für das rekonstruierte Modell aus.

## Aktualisierung vom 5. Oktober 2026

Der Runtime-Katalog erkennt neue Modelle, DTOs, Seiten, Enumerationen und Dienste
aus geladenen Ruby-Dateien ohne manuelle Manifeständerungen. Anwendungen mit
`runtime_model: ruby` laufen ohne MPR-Zugriff; ältere Exporte müssen dafür erneut
exportiert werden. Löschen und Umbenennen alter Katalogeinträge erfordern noch
einen ausdrücklichen Abgleich.

UI-Regeln kombinieren Modulrollen und Sichtbarkeits-/Editierbarkeitsausdrücke mit
geerbten Data-View-Einschränkungen. Unbekannte Rollen gewähren keinen Zugriff;
Serverberechtigungen bleiben maßgeblich. XPath unterstützt zusätzliche String-
und Datumsfunktionen, Perioden und Sitzungszeitzonen, einschließlich kalender-
gerechter Monats-/Jahresgrenzen und DST-Tests. Das belegt keine universelle
Gleichheit aller Datenbanken und nativen Funktionen.

Persistente und transiente Callbacks erreichen Untertypen. Geerbte Validierungen
prüfen Pflichtwerte, Eindeutigkeit über Untertyptabellen, Gleichheit, inklusive
Intervalle und UTF-16-Länge beim Commit mit Events. Fehler rollen Transaktionen
zurück und liefern strukturiertes HTTP-422-Feedback. JVM-Regulärausdrücke brauchen
einen expliziten `regular_expression`-Adapter; unbekannte Regeln werden abgelehnt.
Eine Matrix aus 21 Fällen stimmt mit der nativen Runtime überein
([Evidenz](../evidence/validation-parity-2026-10-05.json)). Gleichheit verwendet
`Value` im nativen Speicher. Datumsgrenzen ohne Uhrzeit sind geprüft; eine von
MxBuild akzeptierte Grenze mit Uhrzeit wurde beim Runtime-Start abgelehnt.

Geänderte VetClinic-Ruby-Quellen bestanden Dienstausführung, neue Modellspalte,
Seitenprojektion, Persistenz nach Neustart, Rollback und Löschen bei verbotenem
MPR-Zugriff ([Evidenz](../evidence/vetclinic-ruby-2026-10-05.json)). Native
Lifecycle-Callbacks teilen jetzt die API-Transaktion.

Die [Windows-Zertifizierung](windows-studio-pro.md) bestand sechs lokale native
Builds und CRUD in der offiziellen Runtime. VetClinic bestand Darstellung mit
Theme und native Client-API-CRUD. Der [Bericht](../evidence/native-2026-10-05.json)
grenzt dies von vollständiger Formular-, Theme-, Fremdwidget-, Java/JS- und
Mobil-Layout-Parität ab. Der wöchentliche Workflow ergänzt native Builds und
Headless-Runtime-Prüfungen.

## Hauptrichtung: Mendix → Ruby + React/TypeScript

Ziel ist ein editierbares Ruby-Backend mit React/TypeScript-Frontend ohne Mendix-
Runtime. Die Rückübersetzung in ein MPR ist ein zusätzlicher Vertrag.
`runtime_only` bedeutet nicht uneditierbar. `portability --require-native` prüft
Ruby → Mendix, nicht die Vollständigkeit der Konvertierung nach Ruby.

Alte Exporte können weiterhin eine interne MPR-Kopie lesen. Neue Exporte mit
`runtime_model: ruby` erzeugen das Laufzeitmodell aus Ruby-Definitionen.
Nicht übersetzte Varianten, Custom Actions ohne Adapter und nicht unterstützte
Widgets bleiben offene Konvertierungslücken.

Editierbarkeit, Ausdrucksbedingungen, Read-only-Stil, Platzhalter, Passwortmodus,
Maximallänge, ARIA-Label/Pflichtkennzeichnung, Tab-Reihenfolge und Autocomplete
werden als Ruby-Seitenoptionen exportiert. Änderungen in `app/pages/**/*.rb`
wirken ohne MPR-Neukompilierung. Verschachtelte Data Views können eine gesperrte
übergeordnete View nicht entsperren. Unbekannte Bedingungen bleiben gesperrt;
Modulrollen werden gemeinsam mit unterstützten Ausdrücken geprüft. Backend-
Autorisierung bleibt unabhängig von dieser UI-Steuerung.

Fokus-, Änderungs- und Austrittsaktionen erhalten den Fokus und warten bei Bedarf
auf Schreiboperationen. Serverobjekte werden nicht mehr implizit transient;
Schreibfehler einschließlich 404 bleiben sichtbar. `listen_to` verwendet die
Auswahl des benannten Grids. Mehrstufige Assoziationen enden bei leeren Verweisen,
ohne eine uneingeschränkte Entitätsabfrage auszuführen.

Das Fixture `spec/fixtures/ruby_frontend_editability/project.rb` und das Szenario
`spec/fixtures/frontend_browser/ruby_editability_flow.json` prüfen Editierbarkeit,
Auswahl und Persistenz nach Neuladen in Ruby/React. Komponententests ergänzen
Fokus, Fehlerfälle, Ausdrücke und Assoziationen. Dies bestätigt diesen Ausschnitt,
nicht das gesamte Frontend oder die Unabhängigkeit von jeder Baseline.

Radiogruppen unterstützen Boolean-/Enum-Auswahl, Beschriftungen, horizontale oder
vertikale Anordnung, Tastaturbedienung, Persistenz und Fokus-/Austrittsereignisse.
Geerbte Schreibsperren bleiben erhalten. Unbekannte Werte werden ohne Mutation
angezeigt. Kurze und qualifizierte Enum-Werte werden erkannt; Schreiboperationen
behalten die empfangene Darstellung bei. Enum-Bedingungen unterscheiden weiterhin
verschiedene qualifizierte Typen. Werte und Übersetzungen exportierter Enums stammen
aus Ruby-Definitionen; nicht geladene Legacy-Definitionen verwenden das Manifest.
Nach Quelländerungen die Anwendung neu laden. Anwendungen mit `runtime_model: ruby`
erkennen geladene Deklarationen und gleichen Löschungen und Umbenennungen ab.
Legacy-Einträge benötigen einen neuen Export. Das Manifest bleibt als private
Rekonstruktionsmetadaten erhalten; der Runtime-Katalog braucht keine manuelle Pflege.

Seitentitel verwenden den geladenen Ruby-Titel. Tabs zeigen ein Panel, unterstützen
Pfeile/Home/End und erhalten Eingaben bereits geöffneter Panels; ungeöffnete Panels
werden erst bei Bedarf geladen. Das Fixture `ruby_frontend_core_widgets` und das
Szenario `frontend_browser/ruby_core_widgets_flow.json` prüfen dies einschließlich
Enum-Bedingungen und Persistenz. Nicht projizierte native Tab-Varianten bleiben offen.

MXRB kennzeichnet jedes Artefakt einer Ruby-Anwendung als `native` (editierbares
MPR-Dokument), `preserved_native` (verlustfrei im Mendix-Sidecar erhalten) oder
`runtime_only` (benötigt die MXRB-Runtime).

```bash
bundle exec mxrb portability .
bundle exec mxrb portability . --json
bundle exec mxrb portability . --require-native
```

Der letzte Befehl schlägt fehl, wenn Runtime-only-Code vorhanden ist. Ruby-
Entitäten und Attributregeln werden im Domain Model materialisiert. Unterstützte
Microflow- und Nanoflow-Graphen werden als editierbare `native`-Blöcke exportiert.
Studio-Pro-Seiten müssen `Page.native` verwenden; eine eigene React-Route bleibt
React-Code und wird entsprechend ausgewiesen.

React/TypeScript, das in Mendix laufen soll, wird als offizielles Pluggable Widget
gebaut:

```bash
bundle exec mxrb widgets new OrderSummary widgets-src
bundle exec mxrb widgets build widgets-src/OrderSummary --project "$PROJECT_ROOT"
bundle exec mxrb widgets sync project.rb build/App.mpr
```

Das Browser-Scaffold verwendet ein HttpOnly-/SameSite-Session-Cookie und CSRF-
Token, keinen Bearer-Token in `localStorage`. Unter HTTPS ist
`MXRB_SECURE_COOKIES=true` zu setzen.

Für LazyVim: Abhängigkeiten installieren und `nvim .` öffnen. Nützliche Kürzel
sind `gd`, `gr`, `K`, `<leader>ca`, `<leader>cr`, `<leader>cf` und `<leader>xx`.

Offizielle Referenzen:

- <https://docs.mendix.com/apidocs-mxsdk/apidocs/pluggable-widgets/>
- <https://www.npmjs.com/package/@mendix/generator-widget>
