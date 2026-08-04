# MXRB: Ruby über alles

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
