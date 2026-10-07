# Echte Portabilität zwischen Ruby, TypeScript und Mendix

## Älteres Feedback und Frontend-Konstanten

`JS_GetSingleLocalStorageObjectItem`, verwendet von Sudoku und RubyBridgeSandbox,
erhält einen anhand des Quelltext-SHA-256 ausgewählten Adapter. Er verwendet die
Modellparameter `LocalStorageKey` und `ObjectItemKey` und liefert bei fehlenden
Einträgen `""`; der neuere Getter liefert dagegen `null`.

Frontend-Ausdrücke lösen `@Module.Constant` über die aktuellen, für den Client
freigegebenen Ruby-Definitionen auf. Private und ausgeschlossene Konstanten fehlen
im Schema; Integer, Boolean und Decimal behalten ihre Typen. Beim Laden der
Anwendung werden frühere Registrierungen ersetzt. Nicht verfügbare Referenzen
erzeugen explizite Fehler.

Die unverändert exportierten Nanoflows beider realer Projekte bestanden mit
fehlendem, leerem und gefülltem Speicher. Der Fixture verwendet eine Konstante
als Speicherschlüssel und prüft dasselbe Verhalten in Ruby und Mendix.
[Nachweis](../evidence/legacy-feedback-2026-10-07.json).

## Abfragbare OQL-Views erzeugen

`oql_view` erhält das Persistenzflag der Entität. Neue Views verwenden den für
Mendix-Datenbankabfragen erforderlichen persistenten Standard; die OQL-Quelle
verhindert weiterhin eine physische SQLite-Tabelle. Zuvor erzwang die Erzeugung
`Persistable=false`, wodurch MxBuild Abrufaktivitäten ablehnte. Nach der Korrektur
bestanden zwei Builds und zwei Laufzeiten in der Windows-VM mit identischen
Ergebnissen des Originals und Wiederaufbaus sowie unveränderten Hashes.
[Nachweis](../evidence/oql-view-persistence-2026-10-07.json).

Die Ruby-Laufzeit unterstützt außerdem einfache Projektionen einer persistenten
Entität: Spalten mit optionalen Aliasnamen und `ID` als Referenzassoziation.
Views lesen gespeicherte Werte, berücksichtigen Commits und Löschungen und
weisen Schreibzugriffe zurück. OQL-Text wird validiert und nie direkt als SQL
ausgeführt. Joins, Filter, Aggregate und verkettete Views sind weiterhin nicht
unterstützt und erzeugen explizite Fehler. Acht Ergebnisse stimmten zwischen
Ruby und beiden Mendix-Laufzeiten überein; 41 Browserschritte bestanden ohne
MPR-Zugriff. Der Modellabruf in acht realen Projekten bestand für alle 98
Entitäten, einschließlich `MyFirstModule.LocationsView`.
[Ausführungsnachweis](../evidence/oql-view-execution-2026-10-07.json).

## Nanoflow-Commons-Speicher

`GetStorageItemString`, `SetStorageItemString`, `RemoveStorageItem`,
`StorageItemExists` und `ClearLocalStorage` erhalten Web-Adapter, ausgewählt
anhand des SHA-256 der Originalquelle. Die Modellparameter heißen `Key` und
`Value`. Pflichtfeldfehler, fehlende gegenüber leeren Werten, Entfernen und
Leeren bleiben erhalten. `ClearLocalStorage` leert wie das Original den gesamten
Speicher des aktuellen Ursprungs.

Validierung: 60 Vergleiche mit dem Original-JavaScript, 176 Frontend-Tests,
51 Chromium-Schritte ohne MPR-Zugriff sowie zwei Builds und zwei Laufzeiten
in der Windows-VM mit identischen Ruby-Ergebnissen und unveränderten Hashes.
Alle 2.326 Ruby-Beispiele bestanden bei 100% Zeilen- und Zweigabdeckung.
Audit und identischer Wiederaufbau des echten Sudoku-Projekts bestanden.
[Nachweis](../evidence/commons-storage-2026-10-07.json).
Der Umfang ist Web-`localStorage`; React Native `AsyncStorage` ist nicht implementiert.

## Nanoflow-Commons-Aktionen und Listen

Der Export registriert `Base64Encode`, `Base64Decode`, `GetGuid`, `GetPlatform`
und `FindObjectWithGUID` nur bei übereinstimmenden Hashes der geprüften Quellen.
Base64 verwendet `js-base64` 3.7.7 aus der nativen Referenz. Die Registrierung
erhält den Modellparameter `EntityObject` und gleichzeitig die Feedback-Adapter.
Exportierte Nanoflows erstellen außerdem Listen und fügen Objekte hinzu,
entfernen sie oder leeren die Liste, ohne bestehende Listenreferenzen zu ersetzen.

22 Vergleiche mit dem Original-JavaScript, 169 Frontend-Tests und 13 Chromium-
Schritte ohne MPR-Zugriff bestanden. Zwei Builds und Runtimes in der Windows-VM
bestätigten identische Original-/Roundtrip-Ergebnisse und unveränderte Quellen.
Das Szenario zertifiziert Web; Umgebungserkennung ist keine Zertifizierung
einer React-Native- oder Cordova-Anwendung.
[Nachweis](../evidence/nanoflow-commons-2026-10-07.json).

## CustomChart mit Plotly

`CustomChart` lädt Plotly 3.0.1 bei Bedarf und übernimmt JSON-Daten, Layout und
Konfiguration aus dem Modell. Statische und attributgebundene Datenreihen werden
aneinandergefügt; Kontextänderungen zeichnen das Diagramm neu. Abmessungen,
Höhenbegrenzungen, Legenden, Achsen und Werkzeugleiste bleiben erhalten. Ein Klick
schreibt die `bbox` des ersten Punktes ins Ereignisattribut, führt die konfigurierte
Aktion aus und leert das Attribut. Laufende Aktionen werden geschützt; beim
Entfernen der Komponente wird das Diagramm freigegeben.

Die Abnahme vergleicht Datenreihen, Titel, Skala, Größe und Klickverhalten vor und
nach einer Änderung. 160 Frontend-Tests und zehn Chromium-Schritte ohne MPR-Zugriff
bestanden. Die vollständige Engine lädt bei Bedarf etwa 1,33 MB gzip. Der interne
Playground/Editor, seine Initialisierungseffekte auf Beispieldaten und die
Zertifizierung sämtlicher Diagrammtypen sind nicht enthalten. Die übrigen
Diagramm-Widgets behalten ihren bisherigen Optionsumfang.

Die Windows-VM bestätigte beide Builds und Runtimes, Original und Roundtrip,
mit identischen Ruby-Ergebnissen und unveränderten Eingabe-Hashes.
[Nachweis](../evidence/custom-plotly-2026-10-07.json).


## Speicheraktionen im Browser

Drei Aktionen des Feedback Module erhalten TypeScript-Adapter, wenn der Hash
der Originalquelle übereinstimmt: Wert lesen, `ShowEmail` lesen und `ImageB64`
schreiben. Die Registrierung erhält Parameternamen und deren Groß-/Kleinschreibung.
Ungültiges JSON, fehlende Werte und Speicherfehler behalten das geprüfte Verhalten.

Alle 33 Vergleiche mit dem Original-JavaScript bestanden. Chromium führte zehn
Schritte ohne MPR-Zugriff aus, einschließlich Persistenz nach neuer Navigation.
Die Windows-VM bestätigte identische Ergebnisse im Original und im Roundtrip.
Geänderte Quellen, natives AsyncStorage und Offline-Synchronisation sind nicht
enthalten. Siehe den [Nachweis](../evidence/feedback-storage-2026-10-07.json).

## Java-Adapter anhand geprüfter Quellen

Der Export erkennt zwei Implementierungen des Feedback Module am SHA-256 der
Java-Quelle: `ValidateEmail` und `XSS_Sanitizer`. Nur geprüfte Versionen erzeugen
explizite Registrierungen in `config/adapters.rb`; fehlende oder geänderte
Quellen benötigen weiterhin einen projektspezifischen Adapter. Die Ausführung
verwendet Ruby ohne MPR oder JVM. Registrierungen bleiben editierbarer Ruby-Code.

Die Tests vergleichen 32 Eingaben mit dem Java-Original, einschließlich Unicode,
leerer Werte und null. Die ältere Aktion `XSS_Sanitizer` behält ihr Verhalten
mit regulären Ausdrücken; sie ersetzt weder HTML-Escaping noch eine
Sanitierungsrichtlinie der Anwendung. Weitere Java-/JavaScript-Aktionen und
externe Integrationen brauchen eigene Implementierung und Abnahme.

## Strukturierte Beschriftungen

Beschriftungen unterstützen Übersetzungen, Ersatztexte, Attribut- und
Ausdrucksparameter, Zahlen-/Datumsformate sowie Seiten-, Snippet- und
Widget-Objekte. Ruby-Deklarationen erhalten diese Metadaten beim Roundtrip.
Das Frontend verwendet die gewählte Sprache und bewahrt Decimal-Präzision
auch jenseits des exakten Number-Bereichs. Serien behalten ihren Kontext.

Das Szenario chart-captions vergleicht Namen und Werte vor und nach einer
Änderung in der nativen Runtime. Unbekannte Datumsmuster werden ausdrücklich
abgelehnt. Erweiterte Plotly-Optionen bleiben ein separater Arbeitsbereich.

## Decimal-Präzision

Ruby verwendet `BigDecimal`, das Frontend `decimal.js`. Decimal-Literale,
Arithmetik und Vergleiche vermeiden zwischenzeitliche `Float`-/`Number`-Konvertierungen.
Die Division nutzt 38 signifikante Stellen entsprechend der installierten Runtime
11.12.1. `round` berücksichtigt `HalfUp`/`HalfEven`; der Export übernimmt `DecimalScale`.
Auch `floor`, `ceil`, `abs` und `parseDecimal` ohne Format arbeiten mit exakten Werten.

Die interne API überträgt Decimal als `{"__mxrb_decimal":"9007199254740993.12345678"}`.
TypeScript-Erweiterungen verwenden die Hilfsfunktionen aus `bridge/decimal`.
Eingabefelder, Seitenparameter, Filter, Sortierung, Entwürfe und Nanoflows erhalten
die Genauigkeit. Diagrammkoordinaten werden erst zur Darstellung in Gleitkommazahlen umgewandelt.

SQLite speichert kanonischen Decimal-Text. Beim Commit gelten Skalierung,
Rundung und Wertebereich des Projekts. Vorhandene `REAL`-Spalten werden unter
Erhalt der Zeilen migriert; bereits verlorene Stellen lassen sich nicht rekonstruieren.
Externes SQL benötigt dezimale Vergleiche statt textueller SQLite-Sortierung.
API-Clients müssen das Decimal-Tag zusammen mit dem neu generierten Frontend übernehmen.
Lokalisierte Formatierung und Java-Formatmuster sind weiterhin nicht abgedeckt.

[Decimal-Nachweise](../evidence/decimal-runtime-2026-10-06.json).

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

## Gestapelte Diagramme und Punktaktionen — 6. Oktober 2026

Balken- und Säulendiagramme unterstützen `barmode: "stack"`. Die Basiswerte
werden je Kategorie in der Reihenfolge der Datenreihen addiert, einschließlich
negativer Werte und Null. Die Achsenskalierung berücksichtigt Basis und Summe.
`staticOnClickAction` und `dynamicOnClickAction` verwenden die Ereignislaufzeit
der Seite mit dem Datensatz des Punkts, Bestätigung und Ausführungssperre.
Klick, Enter, Leertaste und die zugängliche Datentabelle lösen die Aktion aus.

Bei Aggregation entspricht der Punktindex dem Index in der sortierten
Quelldatenliste, wie beim zertifizierten Mendix-Charts-Paket; dies ist nicht
zwingend der erste Datensatz der aggregierten Kategorie. Punktaktualisierungen
erhalten den Seitenkontext. `chart-interactions` prüft beide Ausrichtungen,
Aggregatklicks, negative Werte und eine neu erstellte Datenreihe.

Die Aggregation horizontaler Balken wird weiterhin nicht unterstützt: Das Charts-Paket gruppiert nach der numerischen Achse und kann Beschriftungen verketten. Die Ruby-Laufzeit meldet diese Einschränkung ausdrücklich. Die horizontale Zertifizierung verwendet nicht aggregierte Punkte, einschließlich wiederholter Kategorien.

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
