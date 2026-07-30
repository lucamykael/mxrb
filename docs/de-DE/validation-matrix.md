# MXRB-Validierungsmatrix

[Português](../pt-BR/validation-matrix.md) · [English](../en-US/validation-matrix.md) · **Deutsch**

Stand: 29. Juli 2026.

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

- 1.772 Artefakte und 3.330 Referenzen;
- 432 Beispiele, keine Fehler;
- 100 % Zeilenabdeckung (5.744/5.744);
- 100 % Branch-Abdeckung (2.190/2.190);
- Sudoku-Modellbewertung: 7/7;
- funktionale Runtime-Tests: 3/3 lokal und 3/3 in Docker.

Ruby-Assertions prüfen Rückgabewerte und persistierte XPath-Anzahlen. Der
Docker-Lauf bestätigte Games 1/2/3 und Cells 81/162/243; JUnit XML ist nur ein
in Ruby erzeugtes CI-Format.

`script/validate_matrix` prüfte 1.506 Units in sechs Round-Trips in 13,733 s.
`script/benchmark` maß 6,8463 s für die vollständige Sudoku-Pipeline.
Deterministisches Fuzzing deckt 250 BSON-Dokumente und 50 atomare
`.mxunit`-Dateien einschließlich Binärwerten ab.

Die Matrix beweist die geprüften Szenarien, nicht universelle Kompatibilität
mit jedem Mendix-Metamodell. Unbekannte `.mxunit`-Kodierungen werden abgelehnt.
