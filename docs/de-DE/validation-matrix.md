# MXRB-Validierungsmatrix

[Português](../pt-BR/validation-matrix.md) · [English](../en-US/validation-matrix.md) · **Deutsch**

Stand: 13. September 2026.

```text
Original-MPR → validate → export → generate → validate → compare
```

| Projekt | Mendix | Format | Ergebnis |
|---|---:|---|---|
| QueryApiBlogPost | 7.17.0-rc5 | v1 | bestanden |
| Sudoku | 11.12.1 | v2 | bestanden; 409 `.mxunit` |
| MendixApp | 9.6.1 | v1 | bestanden |
| ConnectorKitDemo | 7.5.0 | v1 | bestanden |
| TreeviewDemo | 5.21.4 | v1 | bestanden |
| GridViewPlayground | 6.10.8 | v1 | bestanden |

Am 13. September wiederholte `script/validate_matrix` die Matrix mit **6/6
erfolgreichen Läufen**: 1.506 Units, 1.734 Artefakte und 3.388 Referenzen in
19,278 Sekunden.

## Zusätzliches lokales Inventar

`script/certify_mprs --cycles 2 --repair-hashes` zertifizierte sieben weitere
MPRs in 14 aufeinanderfolgenden Roundtrips: **7/7 bestanden**, 2.799 Units,
3.238 Artefakte und 4.819 Referenzen in 100,544 Sekunden. Enthalten sind LearnNow, SLATaskApp,
SLATaskAppNative, MyFirstModule, CourseManager, RubyBridgeSandbox und
VetClinic.

SLATaskApp enthielt einen veralteten Content-Hash, RubyBridgeSandbox zwei. Das
Gate reparierte ausschließlich `Unit.ContentsHash` in temporären Kopien,
protokollierte die geänderten UUIDs und bewahrte die ursprünglichen BSON-Bytes.
Die Quelldateien wurden nicht verändert. Der zweite Roundtrip deckte außerdem
als Strings deserialisierte Native-Widget-Typen auf und führte zu deren
Korrektur.

Die Rezertifizierung vom 13. September fand und behob zwei weitere Verluste:
Das DSL ergänzte `System.Administrator` in einer exakten nativen Rollenliste,
die diese Rolle nicht enthielt, und der Settings-Codec kannte
`Settings$ConstantValue`, `Settings$SharedValue` und `Settings$PrivateValue`
noch nicht. Fokussierte Regressionstests decken beides ab; private Werte werden
nicht veröffentlicht.

## Tiefe Abdeckung

Der Vergleich umfasst Metadaten, Security, Unit-Baum, Entitäten,
Zugriffsregeln, Beziehungen, Seiten, Widgets, Events, Menüs und vollständige
Microflow-/Nanoflow-Körper. 264 Flow-Körper und 1.304 Seitenknoten aus 25 Typen
sind als bearbeitbares Ruby repräsentiert. Jede native Unit besitzt zusätzlich
einen vollständigen bearbeitbaren Eintrag in `.mxrb/native_units.rb`.

## Offizielle Gates

Sudoku 11.12.1: **0 Fehler** in `mx check`, identische 23 Warnungen,
1 Deprecation und 6 Empfehlungen; MxBuild erfolgreich. Mendix 6.10 baute
Original und Rekonstruktion erfolgreich. 7.x und 9.6 zeigten diagnostische
Parität. Die exakte 5.21-Prüfung bleibt wegen WPF auf Windows/Studio Pro eine
ausdrückliche MXRB-Einschränkung und gehört nicht zum direkten automatischen
Gate.

## Semantik, Tests und Runtime

- 1.734 Artefakte und 3.388 Referenzen;
- 1.821 Beispiele, keine Fehler;
- 96,46 % Zeilenabdeckung (35.219/36.511);
- 89,80 % Branch-Abdeckung (14.211/15.825);
- Sudoku-Modellbewertung: 7/7;
- funktionale Runtime-Tests: 3/3 lokal und 3/3 in Docker.

Ruby-Assertions prüfen Rückgabewerte und persistierte XPath-Anzahlen. Der
Docker-Lauf bestätigte Games 1/2/3 und Cells 81/162/243; JUnit XML ist nur ein
in Ruby erzeugtes CI-Format.

Das 11.12.1-Gate enthält nun zusätzlich ein authentifiziertes Chromium-Szenario
mit Login, Home-/Orders-Navigation, deterministischen DOM/Layout/Style/ARIA-
Snapshots, Screenshots, explizitem SHA-256-Baseline-Vergleich, Fehlererkennung
und echtem Logout. Alle drei `page --chain`-Pfade werden als gültiges MPR
materialisiert und durch den Compiler-Preflight geprüft. Die mit
`page --template` erzeugten Dashboard- und vertikalen Formularseiten wurden
zusätzlich in der Runtime mit geprüftem berechnetem CSS ausgeführt.

Die echten Mendix-Projekte sind externe Zertifizierungseingaben und werden nie
in diesem Repository gespeichert. Vor `script/validate_matrix` muss
`MXRB_FIXTURES_ROOT`, vor `script/benchmark` `MXRB_BENCHMARK_MPR` und für die
optionalen Connector-Spezifikationen `MXRB_CONNECTOR_FIXTURE` gesetzt werden.
`MXRB_ACCEPTANCE_MPRS` akzeptiert eine oder mehrere, durch den systemeigenen
Pfadseparator getrennte MPR-Dateien für das Web-Kompatibilitäts-Gate. Die Suite
lädt diese vier Schlüssel aus der ignorierten `.env`, ohne bereits gesetzte
Prozessvariablen zu überschreiben.
`.env.example` dokumentiert nur die Variablennamen; arbeitsplatzspezifische
Werte gehören in die ignorierte `.env` oder in die Shell-Umgebung.

`script/validate_matrix` prüfte 1.506 Units in sechs Round-Trips in 19,278 s.
Nach der Korrektur der erforderlichen `mprcontents`-Kopie für v2-MPRs lief
`script/benchmark` dreimal unter Ruby 4.0.5. Der Median betrug insgesamt
9,6308 s; der warme semantische Cache war im Median 87,1-mal schneller als der
kalte. Das frühere Ergebnis von 6,8463 s ist wegen einer anderen
Schrittzusammensetzung und fehlender Umgebungs-/Budgetdaten kein vergleichbarer
Baseline; ein versioniertes Performance-Budget bleibt offen.
Deterministisches Fuzzing deckt 250 BSON-Dokumente und 50 atomare
`.mxunit`-Dateien einschließlich Binärwerten ab.

Die Matrix beweist die geprüften Szenarien, nicht universelle Kompatibilität
mit jedem Mendix-Metamodell. Unbekannte `.mxunit`-Kodierungen werden abgelehnt.

## Widget-Zertifizierung

`script/forms_core_project_gate` ergänzt die Verhaltensabdeckung um ein
strukturelles Gate je Eigenschaft. Für Mendix 11.12.1 materialisiert es alle
455 geerbten Eigenschaftsvorkommen der 41 Core-Widgets, öffnet die MPR erneut,
exportiert lesbares Ruby ohne opake Fragmente, kompiliert neu und vergleicht
jeden typisierten Wert nach erneutem Öffnen. Aktuell sind `imported` und
`compiled` jeweils 455/455. `studio_validated` bleibt 0/455 und darf nur durch
MxBuild-/Studio-Pro-Evidenz in funktional gültigen Widget-Kontexten steigen.

Mit `--mxbuild` und dem offiziellen 11.12.1-Programm wurde die neu kompilierte
MPR ohne Speicherfehler gelesen. Der Oracle-Lauf verweigerte das Paket wegen
625 Konsistenzproblemen, da das Fixture Widgets absichtlich isoliert, die
Login-Seiten, Native-Profile, Datenkontexte, Datenquellen, bestimmte
Layout-Positionen oder ausführbare Referenzen benötigen. Dadurch bleibt das
Gesamt-Gate bei angefordertem Oracle rot und beschreibt die verbleibende Arbeit
für `studio_validated`; die strukturelle Import- und Kompilierungsevidenz bleibt
gültig.

`script/certify_widgets --browser-report REPORT.json App.mpr` ist das
Fail-Closed-Gate für tatsächlich verwendete Widgets des nativen Web-Compilers
und Marketplace-Widgets. Es
verlangt gemeinsam eine Page/Layout-Kompilierung ohne Fallback, die Auflösung
jeder Pluggable-ID auf einen MPK-`.mjs`-Eintrag samt SHA-256, einen nativen
Rspack-Build der Mendix-Version und bestandene Chromium-Evidenz, die alle
geprüften Widget-Typen und IDs ohne sichtbare Runtime-/Widget-Fehler ausweist.

Der MPK-Import oder ein erfolgreicher Bundle-Build allein zertifiziert kein
Verhalten. Widgets mit erforderlicher Datenquelle, Attributbindung oder
Elternplatzierung bestehen nur in einem korrekt konfigurierten Browserszenario.
Zukünftige oder ungeprüfte Pakete scheitern als fehlende Evidenz, statt eine
pauschale Kompatibilitätszusage zu erben.
Das React/TypeScript-Frontend von `--mode ruby` besitzt eine getrennte Spur:
Sein Chromium-Bericht zertifiziert diese Widgets, ohne zu behaupten, dass die
entsprechenden Pluggable-Komponenten auch im Mendix Runtime bestanden haben.
