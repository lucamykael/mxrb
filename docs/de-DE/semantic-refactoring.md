# Semantisches Refactoring

[Português](../pt-BR/semantic-refactoring.md) · [English](../en-US/semantic-refactoring.md) · **Deutsch**

Der semantische Index kombiniert typisierte Artefakte und BSON-Referenzen.
`Project.Navigation` nimmt an Auswirkungsanalyse, Rename und Löschschutz teil.

```ruby
Mxrb.open("Shop.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Home", to: "Landing")
  plan.changes.each { puts _1.inspect }
  plan.apply!
end
```

Jedes Refactoring folgt Plan, Vorschau und `apply!`. Rename aktualisiert BSON
und `_MxrbArchitecture` in derselben Transaktion. Remove blockiert Referenzen
und Kind-Units; Move, Extract, Inline und Domänenmutationen zeigen Änderungen
vor dem Schreiben.

Der Analyzer findet fehlende Ziele, Profile ohne Startziel, doppelte Namen,
unbekannte Benutzerrollen, Ziele ohne Zugriff, nicht aufgelöste Tokens und
unzureichenden Kontrast. Der semantische Cache nutzt Unit-Fingerprints;
`mxrb cache status`, `warm` und `clear` liefern Metriken und Wartung.

`project.semantic_search_artifacts("Bestellung erstellen", limit: 5)` bietet
deterministisches Ranking in Ruby. Das optionale Gem `sqlite-vec` beschleunigt
die Suche in schreibbaren MPRs mit einem KNN-Index aus Backend, Dimension und
Modell-Fingerprint. Der erste Aufruf füllt die Vektoren, bevor der Index als
bereit markiert wird; schreibgeschützte Projekte und Plattformen ohne native
Erweiterung behalten dieselbe In-Memory-API. Der bisherige CLI-Adapter lautet
`mxrb find app.mpr "Bestellung erstellen" --semantic`. Der eigene Befehl
stellt zusätzlich Backend, Ergebnislimit und Kosinusdistanz bereit:

```sh
bundle exec mxrb search "Zahlung" App.mpr
bundle exec mxrb search "Bestellung erstellen" App.mpr --backend onnx --limit 5
```

Die Tabelle enthält Rang, Distanz, qualifizierten Namen und Typ; `--json`
liefert dieselben Felder für Automatisierung.

Für lokale ONNX-Entwicklung aktiviert `BUNDLE_WITH=onnx bundle install` die
optionale Gruppe. `backend: :onnx` und das automatische Backend verwenden dann
die dokumentierte Informers-`embedding`-Pipeline mit
`sentence-transformers/all-MiniLM-L6-v2`. Ein eigener CI-Job setzt
`MXRB_ONNX=1` und führt einen echten Smoke-Test mit 384 Dimensionen aus; die
normale Installation und Testsuite laden das Modell nicht herunter.

Der native sqlite-vec-Smoke-Test verwendet eine eigene Abhängigkeitsdatei für
unterstützte Plattformen: `BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle install`
und danach `MXRB_SQLITE_VEC=1 BUNDLE_GEMFILE=Gemfile.sqlite-vec bundle exec
rspec spec/semantic_search_spec.rb`. So bleibt das Haupt-Lockfile portabel,
während CI die echte Erweiterung prüft.

[Zurück zum Index](README.md)
