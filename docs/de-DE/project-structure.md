# Struktur des exportierten Projekts

[Português](../pt-BR/project-structure.md) · [English](../en-US/project-structure.md) · **Deutsch**

Der von `mxrb export` erzeugte Baum trennt anwendungsweite Richtlinien,
Modulverhalten, erhaltene native Units und Assets:

```text
project.rb
.mxrb/{native_units.json,native_units.rb,assets.json}
app/{security,navigation,design_system}/
modules/Modulname/{domain,application,presentation,infrastructure,security}/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` orchestriert das Laden. Module enthalten das Verhalten. Das
native Manifest erhält Strukturen ohne kompakte DSL; das Asset-Manifest
speichert relative Pfade, Größen und SHA-256-Prüfsummen.

Absolute Pfade, `..`-Traversal, fehlende Dateien und abweichende Prüfsummen
schlagen beim Wiederaufbau sicher fehl. Nur Manifest-Einträge werden geschrieben.

Die Struktur unterstützt Ruby zu einem neuen Mendix-Projekt, Ruby auf einem
exportierten Baseline, Mendix zu bearbeitbarem Ruby und den strukturell
gleichwertigen Mendix → Ruby → Mendix Round-trip.

[Zurück zum Index](README.md)
