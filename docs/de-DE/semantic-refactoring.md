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

[Zurück zum Index](README.md)
