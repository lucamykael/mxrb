# MXRB: Ruby über alles

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
Plotly-Optionen. Aggregationen, dynamische Reihen und Balkenmodi außer `group`
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
