# MXRB-Validierungsmatrix

[Português](../pt-BR/validation-matrix.md) · [English](../en-US/validation-matrix.md) · **Deutsch**

Stand: 11. August 2026.

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

Am 11. August wiederholte `script/validate_matrix` die Matrix mit **6/6
erfolgreichen Läufen**: 1.506 Units, 1.734 Artefakte und 3.388 Referenzen in
16,381 Sekunden.

## Zusätzliches lokales Inventar

`script/certify_mprs --cycles 2 --repair-hashes` zertifizierte sieben weitere
MPRs in 14 aufeinanderfolgenden Roundtrips: **7/7 bestanden**, 2.799 Units,
3.238 Artefakte und 4.819 Referenzen. Enthalten sind LearnNow, SLATaskApp,
SLATaskAppNative, MyFirstModule, CourseManager, RubyBridgeSandbox und
VetClinic.

SLATaskApp enthielt einen veralteten Content-Hash, RubyBridgeSandbox zwei. Das
Gate reparierte ausschließlich `Unit.ContentsHash` in temporären Kopien,
protokollierte die geänderten UUIDs und bewahrte die ursprünglichen BSON-Bytes.
Die Quelldateien wurden nicht verändert. Der zweite Roundtrip deckte außerdem
als Strings deserialisierte Native-Widget-Typen auf und führte zu deren
Korrektur.

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

- 1.778 Artefakte und 3.387 Referenzen;
- 1.329 Beispiele, keine Fehler;
- 100 % Zeilenabdeckung (23.771/23.771);
- 100 % Branch-Abdeckung (9.704/9.704);
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

`script/validate_matrix` prüfte 1.506 Units in sechs Round-Trips in 14,760 s.
`script/benchmark` maß 6,8463 s für die vollständige Sudoku-Pipeline.
Deterministisches Fuzzing deckt 250 BSON-Dokumente und 50 atomare
`.mxunit`-Dateien einschließlich Binärwerten ab.

Die Matrix beweist die geprüften Szenarien, nicht universelle Kompatibilität
mit jedem Mendix-Metamodell. Unbekannte `.mxunit`-Kodierungen werden abgelehnt.

## Widget-Zertifizierung

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
