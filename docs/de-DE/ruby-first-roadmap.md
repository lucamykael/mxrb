# MXRB: Ruby über alles

## XPath-Division und Rest mit Vorzeichen

Ganzzahliges `div` schneidet in Richtung null ab; `mod` behält das Vorzeichen
des Dividenden. Beispielsweise gelten `-12 div 5 = -2` und `-12 mod 5 = -2`.
Dezimaloperanden behalten einen dezimalen Quotienten. Fünfzehn neue Fälle
bestanden im Original und im Ruby-Roundtrip unter Studio Pro 11.12.1;
alle 87 Kompatibilitätsergebnisse stimmen überein. Vergleiche ganzzahliger
Ausdrücke mit gebrochenen Konstanten und gemischte Ganzzahl-/Dezimalkonvertierung
sind nicht zertifiziert. Siehe den
[Nachweis](../evidence/xpath-arithmetic-2026-10-07.json).

## Validierung der XPath-Division

Der Parser lehnt `/` als Division vor der Datensatzabfrage ab, auch bei leeren
Tabellen und verschachtelten Prädikaten. Schrägstriche bleiben in
Assoziationspfaden, Variablenzugriffen und Zeichenketten gültig. `mx check`
11.12.1 lehnt `[Rank / 2 = 1.5]` mit CE0161 ab und akzeptiert
`[Rank div 2 = 1.5]`. Dies ist eine statische Prüfung; der zertifizierte
Ausführungsumfang ist oben beschrieben.

## Umgekehrte XPath-Selbstreferenzen

Der Marker `[reversed()]` kehrt nur den jeweiligen Selbstreferenzschritt um.
Mehrstufige Pfade können normale und umgekehrte Schritte kombinieren;
verschachtelte Prädikate werden weiterhin am verknüpften Objekt ausgewertet.
Die Runtime prüft Mitgliedsberechtigungen und die Sichtbarkeit verknüpfter
Objekte und liest gespeicherte SQLite-Referenzen in der gewünschten Richtung.

Neun reproduzierbare Fälle prüfen Anzahl und Namen der Ergebnisse für Referenzen,
Referenzmengen, gemischte Pfade, leere Ergebnisse und native Speicherung in
Tabellen oder Spalten. Die Ruby-Anwendung prüft Referenzen auch nach erneutem
Öffnen der Datenbank bei verbotenem MPR-Zugriff. Original und Roundtrip bestehen
`mx check` 11.12.1. Alle 115 XPath-Felder des Korpus werden weiterhin geparst,
darunter 19 mit `reversed()`; dies zertifiziert nicht die Ausführung sämtlicher
Projektabläufe. Referenzen zwischen unterschiedlichen deklarierten Entitätstypen,
XPath-Arithmetik und weitere Funktionen bleiben außerhalb dieses Umfangs.
Siehe [Nachweis](../evidence/xpath-reverse-2026-10-06.json) und
[nativen Vertrag](https://docs.mendix.com/refguide/query-over/).

## Layouts, Anmeldung und Export von Ruby-Anwendungen

Mit `native` erstellte Seiten verwenden das angegebene Layout und dessen Slot
`Main`. Exportierte Layouts behalten Klassen und Stile; Tabellen, Navigation und
Popups stellen die für vorhandenes CSS benötigte Struktur bereit. Die Startseite
vermeidet Pflichtparameter und Popups. Geschützte Links öffnen die Anmeldung;
Startfehler werden angezeigt und können erneut versucht werden.

Forms-Widgets verwenden den Katalog ihres Dokuments, ohne übernommene Schemas
einzufrieren. Annotationen zu nicht ausgebbaren Knoten behalten ihren nativen
Graphen, statt eine unvollständige Rekonstruktion zu erzeugen. Dies erweitert
nicht die Ruby-Ausführung dieser Graphen. Der CDP-Reader unterscheidet außerdem
erweiterte Frame-Längen korrekt.

Lokale Prüfung: 2.301 Ruby-Tests mit 100 % Zeilen- und Branch-Coverage, 132
Frontend-Tests, Build und Lint; 22 Browserschritte ohne Konsolenfehler. Der
Sudoku-Roundtrip ist ohne Mendix-Sidecar gültig und identisch. `mx check` 11.12.1
meldet für core-widgets vor und nach dem Roundtrip keine Fehler. Visuelle
Gleichwertigkeit aller Themes und die Ausführung sämtlicher Integrationen sind
nicht Gegenstand dieser Prüfung.
Siehe [Nachweis](../evidence/ruby-runtime-hardening-2026-10-06.json).

## Diagrammaggregation

Diagramme gruppieren wiederholte Kategorien und berechnen `count`, `sum`, `avg`,
`min`, `max`, `median`, `mode`, `first` und `last`. Die Quellreihenfolge bestimmt
den ersten und letzten Wert; Nullwerte werden ausgeschlossen. Datenänderungen
berechnen die Ergebnisse neu. Tabelle und Diagramm zeigen dieselben Aggregate.

Charts 6.2.1 unter Studio Pro 11.12.1 bestätigt alle neun Funktionen für zwei
Kategorien vor und nach dem Einfügen, im Original und nach dem Roundtrip.
Ruby-Chromium besteht 59 Schritte ohne MPR; 109 Frontend-Tests und 100% Ruby-Coverage
bestehen. CI wiederholt den Test mit dem per Prüfsumme fixierten Paket. Geprüft
sind aggregierte Liniendiagrammwerte; dynamische Serien, Stapelung, Punktaktionen
und weitere visuelle Optionen benötigen eigene Verträge.
Siehe [Nachweis](../evidence/chart-aggregation-2026-10-05.json).

## Bedingte und arithmetische Ausdrücke

Das Backend prüft den gesamten Ausdruck und wertet nur den gewählten Zweig von
`if ... then ... else ...` aus. `and`/`or` verwenden Kurzschlussauswertung, auch
wenn der übersprungene Zweig ein leeres Objekt lesen oder einen Fehler auslösen
würde. Backend und Frontend unterstützen nicht abgeschnittene Ergebnisse von
`div` und `:` sowie vorzeichenbehaftete `mod`-Reste. Bedingungen verlangen Boolean.
Der Schrägstrich bleibt für XPath-Pfade erhalten, gilt aber nicht als Division
in Microflow-Ausdrücken.

Studio Pro 11.12.1 bestätigte 36 Fälle vor und nach dem Roundtrip. Exportierter
Ruby-Code führt dieselben Fälle bei verbotenem MPR-Zugriff aus. 100 Frontend-Tests
bestehen; Ruby-Zeilen und -Branches sind zu 100 % abgedeckt. Die vorhandene
Float/number-Präzision bleibt; beliebige Decimal-Präzision und Kalender-/DST-
Operationen sind nicht zertifiziert. Siehe [Nachweis](../evidence/expression-parity-2026-10-05.json)
und [Mendix-Arithmetik](https://docs.mendix.com/refguide/arithmetic-expressions/).

## Typisierte Präsentationseigenschaften

Design-Toggles verwenden jetzt `design_property "Phone", toggle: true`, auch in
verschachtelten Gruppen. Zum Deaktivieren wird die Deklaration entfernt;
`toggle: false` wird abgelehnt, da das native Format keinen deaktivierten Wert
enthält. Identitäten bleiben privat. Alte Widget-Schemas unterstützen
`phonegap_enabled true` oder `false` und unterscheiden eine fehlende Eigenschaft.
FirstMedix-TreeNode-Eigenschaften erhalten typisierte Deklarationen.

Alle acht Projekte bestehen die öffentliche Quellcodeprüfung und erzeugen ohne
Mendix-Sidecar gültige, identische MPRs. Veraltete Hashes in SLA und RubyBridgeSandbox
werden nur in temporären Kopien repariert. Alle 45 FirstMedix-Widget-Schemas bleiben
bytegleich. Damit sind die beiden Darstellungslücken der vorherigen Prüfung
behoben; PhoneGap-Ausführung und sämtliche visuellen Varianten sind nicht zertifiziert.
Siehe [Nachweis](../evidence/presentation-source-contracts-2026-10-05.json).

## Zusätzliche Präsentationsdateien

Layouts und Snippets verwenden bei der Umwandlung in typisierte `Mxrb::Forms`-
Konstruktoren temporären Speicher. Neue Exporte der acht geprüften Projekte
enthalten keine unreferenzierten BSON-Hilfsdateien mehr; zuvor waren es 112.
Vorhandene Dateien und anderweitig benötigte Fragmente bleiben erhalten.
Roundtrip-Tests vergleichen den MPR-Inhalt. Dateizahlen belegen keine allgemeine
Runtime-Kompatibilität.

Die erweiterte Quellcodeprüfung fand zwei weitere generische Darstellungen:
Design-Property-Toggles in SLA und ein altes TreeNode-Schemafeld in FirstMedix.
Beide wurden mit der oben beschriebenen Implementierung behoben.
Siehe [Prüfergebnisse](../evidence/presentation-fragments-2026-10-05.json).

## Persistierbare Seitenobjekte vor dem Commit

Objekte einer Datenquelle bleiben über mehrere Anfragen editierbar, ohne in
Abfragen gespeicherter Datensätze zu erscheinen. SQLite hält private Kopien auf
dem Server. Ein undurchsichtiger, an den Benutzer gebundener Token läuft nach
einer Stunde ab. Verborgene Standardwerte bleiben auf dem Server; Lese-, Schreib-
und Erstellungsrechte gelten weiterhin. Commit, Löschen und explizites Rollback
widerrufen den Token atomar. Fehlgeschlagene Aufrufe speichern keine Teiländerungen.

Die Seite verwendet ihre bereits geladene Datenquelle wieder. Antworten von
Microflows aktualisieren den Entwurf und erhalten Änderungen, die während der
Anfrage eingegeben wurden. Save speichert auch unveränderte neue Objekte.

`persistent_page_drafts_flow.json` prüft Bearbeiten und Save im Ruby-Browser ohne
MPR-Zugriff. Studio Pro 11.12.1 bestätigte Quelle und Roundtrip: null gespeicherte
Objekte beim Öffnen und nach der Änderung, eines nach Save. Die Fixture benötigt
`MXRB_DATAGRID_PACKAGE`; CI prüft Revision und SHA256 des Data-Grid-2-Pakets.
Siehe [Nachweise](../evidence/page-drafts-2026-10-05.json).

## Editierbare Menü-Icons und JavaScript-Callbacks

Die Prüfung von acht Projekten fand 125 zusätzliche BSON-Dateien. Für 112 davon
existierten bereits typisierte `Mxrb::Forms`-Deklarationen ohne verbleibenden
Verweis auf die Hilfsdatei. BSON-Dateien sind daher kein Maß für nicht editierbare
Dokumente. Die 13 generischen Fälle waren zwölf Menüs mit Collection-Icons und
die Signatur von `NativeMobileActions.RegisterDeepLink`.

Menüs exportieren jetzt `icon: collection_icon("Modul.Collection.Icon")`. Icons
lassen sich hinzufügen, ändern, durch Glyphen ersetzen und entfernen; die
Identitäten der Menüeinträge bleiben erhalten. Native Standardfelder und
BSON-Listenmarker bleiben beim Neuaufbau erhalten, entfernte Einträge bleiben
entfernt. JavaScript-Parameter unterstützen `kind: :nanoflow` mit stabilen IDs.
Die SLA-Menüs und die Aktionssignatur sind nach dem Neuaufbau strukturell identisch.

Das Ruby-Frontend erhält lokale Schriftdateien mit Modul- und Collection-Namen und editierbare
Icon-Ressourcen. `editable_menu_icons_flow.json` prüft Darstellung und Navigation
in Chromium ohne MPR-Zugriff. Der Windows-Test prüft Menü und Callback-Signatur
im Original und nach dem Neuaufbau; er führt den Callback nicht aus und
zertifiziert keine native Deep-Link-Integration.

Neue Exporte der acht Projekte enthalten weder generische `native_document`-
Deklarationen noch opake Menüs. Die 112 Hilfsdateien werden nicht mehr erzeugt; die typisierten
Ruby-Deklarationen bleiben editierbar. Das belegt keine vollständige Laufzeit-, Mobile-
oder Java/JavaScript-Kompatibilität. Siehe
[Nachweis der Editierbarkeit](../evidence/editability-2026-10-05.json).


## Diagramme mit gebundenen Daten

Das Frontend liest autorisierte Entitätsquellen mit XPath und Kontext, sortiert
Datensätze und aktualisiert Diagramme nach Änderungen. Linien-, Flächen-, Säulen-,
horizontale Balken-, Blasen-, Zeitreihen-, Kreis- und Heatmap-Diagramme verwenden
echte Werte; CustomChart akzeptiert explizite JSON-Reihen für Balken und Scatter.
Eine zugängliche Tabelle erhält die Werte, gemeinsame Kategorien werden über
Reihen hinweg ausgerichtet und Nullwerte werden nicht zu Nullen. Quellenfehler
erscheinen als Fehler anstelle eines dekorativen Diagramms.

Die Fixture `marketplace_chart_project.rb` in `spec/fixtures/frontend_browser`
verwendet `MXRB_OUTPUT_PATH` und `MXRB_CHARTS_PACKAGE`. Die Zertifizierung nutzt
Charts 6.2.1; das lokal vorhandene Paket 4.2.4 scheiterte beim React-Client-Build
in Studio 11.12.1. Das Drittanbieterpaket wird nicht im Repository verteilt.

Das Orakel zeigte außerdem fehlende optionale Templates. Der Generator erzeugt
leere Texte für aktive Quellen, erhält inaktive Quellen und explizites Löschen
und exportiert Namen verschachtelter Datenreihen. Browsertests führen die
Ruby-Version mit verbotenem MPR-Zugriff aus.

Die native Prüfung umfasst Werte und Aktualisierung von Linien-, Balken- und
Kreisdiagrammen. Sie belegt keine vollständige visuelle Gleichheit, parametrisierten
Templates, Punktereignisse, Themes, benutzerdefinierten Layouts oder sämtliche
Plotly-Optionen. Dynamische Reihen und Balkenmodi außer `group`
benötigen weiterhin einen Adapter; der Renderer weist diese Konfigurationen ab,
anstatt falsche Daten darzustellen.
Siehe die [Diagrammnachweise](../evidence/chart-data-2026-10-05.json).
Windows-CI wiederholt dieses Szenario mit per Commit und Prüfsumme fixiertem Paket.

## Weitere Überarbeitung von Katalog, Regeln und Widgets

Der Katalog für Anwendungen mit `runtime_model: ruby` gleicht entfernte und
umbenannte geladene Deklarationen ab, ohne das Exportmanifest zu verändern.
Persistente Umbenennungen verwenden `renamed_from`; das Entfernen einer Klasse
erlaubt kein Löschen ihrer Tabelle. Der Legacy-Modus behält nicht deklarierte
Metadaten weiterhin bei.

Regeln werden als `flow :rule`-Services mit erhaltenem Exportlevel exportiert.
Entscheidungen rufen die aktuelle Ruby-Implementierung auch nach Änderungen auf;
Annotationen können auf diese Entscheidungen verweisen. Der Writer erzeugt
textuelle Beschriftungen und akzeptiert unveränderliche Deklarations-Snapshots.

Das Frontend bietet `registerMarketplaceWidget` für Adapter anhand der exakten
Widget-Identität. Bilder, Schieberegler, Bereiche, Fortschritt, Bewertungen,
Farben und Enumerationsschaltflächen verwenden gebundene Eigenschaften und
Daten unter Beachtung der geerbten Bearbeitungsregeln. Scanner, Java/JS-Aktionen
und weitere native Varianten benötigen weiterhin eigene Implementierungen und
Prüfungen; der Diagrammumfang ist oben beschrieben.

Das in Ruby bearbeitete VetClinic bestand authentifizierte Chromium-Tests für
Erstellung und persistiertes Lesen bei 1280×900 und 390×900, während MPR-Zugriffe
verboten waren. Die Vorbereitung steht in
`spec/fixtures/frontend_browser/prepare_vetclinic_edited.rb`; der Prüfserver
heißt `serve_without_mpr.rb` im selben Verzeichnis. Beide verwenden einen neuen
Export; die Originalprojekte bleiben unverändert.


Eine weitere Runde bestand zehn Builds: Verträge, Darstellung, Core-Widgets,
Validierung und Kompatibilität, jeweils als Original und Ruby-Round-trip.
Zehn Regel- und String-Prüfungen bestanden in der Runtime jedes
Kompatibilitätspakets. Das Orakel zeigte Fehler bei textuellen Beschriftungen
von Regelentscheidungen und URL-Kodierung auf; diese wurden korrigiert
(Leerzeichen `%20`, Stern `%2A`, Tilde `~`). Siehe die
[Kompatibilitätsnachweise](../evidence/compatibility-2026-10-05.json).


String-Suche und Ausschnitte zählen jetzt UTF-16-Einheiten: `find` beachtet
die Startposition, `findLast` findet das letzte Vorkommen und `substring` lehnt
ungültige Bereiche ab. Vollständige Surrogatpaare bleiben erhalten; ungültige
Unicode-Strings werden ausdrücklich abgelehnt. Zertifizierte native Fälle
stehen im [String-Nachweis](../evidence/string-parity-2026-10-05.json).


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

[Português](../pt-BR/ruby-first-roadmap.md) · [English](../en-US/ruby-first-roadmap.md) · **Deutsch**

## Architekturprinzip

Ruby ist die einzige öffentliche Sprache von MXRB. CLI-Befehle sind dünne
Adapter. Es wird weder MDL noch eine konkurrierende DSL eingeführt. Studio Pro
und MxBuild sind externe Validatoren, keine Abhängigkeiten des Ruby-Kerns.

## Verfügbar

- Tiefes Lesen und Schreiben von MPR v1/v2.
- Export in bearbeitbare Ruby-Projekte.
- Bearbeitbare `native_unit`-Hashes für jede native BSON-Struktur.
- Generierung, Integritätsprüfung, Vergleich und typisierter Diff.
- Semantischer Index, Referenzen, Caller/Callee und Impact.
- Sichere Umbenennung mit Vorschau.
- Sichere Entfernung eigenständiger Units mit Vorschau.
- Statische Analyse und ausführbare Modellbewertungen.
- Funktionale Microflow-Tests ohne JUnit.
- Lokale oder Docker-Ausführung von `mx check`, MxBuild und Runtime.
- Natives Coverage-Gate mit 100 % Zeilen und 100 % Branches im CI;
  ohne explizite Grenzwerte bleibt der lokale Standard strenger bei 100/100.

## Beispiel

```ruby
Mxrb.open("app.mpr") do |project|
  project.references_to("Sales.Order")
  project.callers_of("Sales.Recalculate")
  project.impact_of("Sales.Order")
  project.plan_rename("Sales.Order", to: "Invoice")
  plan = project.plan_remove("Sales.UnusedFlow")
  plan.apply! if plan.safe?
  project.analyze
end
```

Bewertungsdateien sind gewöhnliches Ruby und werden mit
`mxrb evaluate app.mpr evaluation.rb` ausgeführt.

Schreibbare Projekte speichern einen fingerprint-basierten Cache des
semantischen Index im MPR. Schreibgeschützte Öffnungen dürfen ihn
wiederverwenden, verändern das Projekt jedoch nie.
`mxrb cache status`, `warm` und `clear` liefern Metriken und Wartung. Beim
Ersetzen wird zuerst per Upsert geschrieben und erst danach ein veralteter
Eintrag entfernt.

Die exakte native Mendix-5-Validierung bleibt von Windows/Studio Pro abhängig.
Sie ist als entfernte Legacy-Einschränkung dokumentiert und kein aktuelles
Auslieferungs-Gate.

Navigationsprofile lesen und schreiben jetzt native Mendix-Dokumente,
einschließlich rollenbasierter Startziele und rekursiver Menüs. Theme- und
Quell-Assets durchlaufen den Round-trip mit einem Prüfsummenmanifest;
Design-Tokens bieten Inventar, Lint, Kontrastmetriken und eine
Preview-basierte Migration literaler Werte.

Beim Entfernen blockieren eingehende Referenzen und Kind-Units den Plan.
Eingebettete Domain-Modellelemente benötigen ihre typisierte Mutation. Die CLI
zeigt mit `mxrb remove app.mpr Sales.UnusedFlow` nur die Vorschau; `--apply`
schreibt ausschließlich einen sicheren Plan.

Eigenständige Units können innerhalb desselben Moduls in ein Modul oder einen
Ordner verschoben werden:

```ruby
plan = project.plan_move("Sales.Process", to: "Sales.Automation")
plan.apply!
```

Der Plan bewahrt den nativen Containment-Typ und blockiert Domain-
Modellelemente, ungültige Container, Ordnerzyklen und modulübergreifende
Verschiebungen. `mxrb move` zeigt eine Vorschau; erst `--apply` schreibt.

## Offizieller Mendix Marketplace

Diese Befehlsfamilie bleibt von `mxrb module` getrennt. Die dokumentierte
Marketplace Content API unterstützt authentifizierte Suche, Details,
kompatible Versionen, direkten Download, private Unternehmensinhalte und
Sicherheitsaudits. GitHub und lokale MPKs bleiben Fallbacks.

Lokale MPKs werden vollständig und ohne Mendix-Werkzeuge direkt über
Ruby/SQLite/BSON in das Ziel-MPR importiert. Das PAT benötigt
`mx:marketplace-content:read`. Verwundbare Releases werden standardmäßig
abgelehnt; Content-/Version-IDs und Sicherheitsdaten stehen im Lockfile.
Die authentifizierte Kafka-Abnahme und der transaktionale Lifecycle sind jetzt
umgesetzt. `marketplace update` und `marketplace remove` zeigen standardmäßig
nur eine Vorschau, erhalten extern referenzierte IDs, verweigern veränderte
Assets und sichern MPR, `mprcontents`, Cache, Lock und Assets vor explizitem
`--apply`. Auch die authentifizierten Folgeschritte sind umgesetzt:
`marketplace dependencies` löst offizielle Pakete rekursiv aus Referenzen im
eingebetteten MPR, prüft die tatsächliche Modulidentität jedes MPKs, erkennt
projekteigene Module, installiert Blätter zuerst und führt atomaren Rollback
aus. Kafka-Graphen bestanden die Abnahme unter 10.24 und 11.12; Ruby-
Export/Rebuild bewahrt Assets, Prüfsummen und Quell-/Rebuild-Diagnosen.

Die authentifizierte Matrix enthält jetzt DataWidgets 3.11.3 (Content ID
116540, Version ID `e7b6d703-8e47-42f4-bb92-934e3601e71b`) und die unabhängige
offizielle Combo-box-Widget/clientModule-Komponente 219304, Version 2.9.0,
Version ID `dce845f4-d051-4161-847c-016c01703caa`. Die Installation sichert und
ersetzt das zuvor Atlas Core (Content ID 117187) gehörende 2.6.x-Asset. Ruby-
Roundtrips bewahren die Provenienz von Marketplace-Lock, Cache und Originalen;
`script/frontend_acceptance` blockiert Modell-, Asset-, Prüfsummen- oder
Provenienzdrift. Der native Renderer hat für die akzeptierten 10.24- und
11.12-Fixtures null Preflight-Befunde in Quelle und Rebuild.

Die Migrationsschnittstelle ist als `mxrb frontend migrate DATEI.mpr`
umgesetzt: Standard ist die Vorschau, erst `--apply` schreibt einen sicheren
transaktionalen Plan. Diese Migration ist auf der gesamten unterstützten
Frontend-Matrix abgeschlossen. Das optionale externe MxBuild-Orakel liefert
für Quelle und Rebuild unter 10.24 und 11.12 null Fehler; `mx check` bewahrt
außerdem bytegleiche beobachtbare Paketdiagnosen in jedem Round-trip. MXRB
bleibt unabhängig: `mx` und MxBuild sind nur Validierungsorakel, niemals
Generatoren, Mutatoren oder Runtime-Abhängigkeiten.
