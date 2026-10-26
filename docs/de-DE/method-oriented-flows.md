# Microflows und Nanoflows mit Ruby-Methoden

[Português](../pt-BR/method-oriented-flows.md) · [English](../en-US/method-oriented-flows.md) · **Deutsch**

Neue Exporte zeigen den Ablauf in `main_line`. Aktivitäten erhalten benannte
Ruby-Methoden. Parameter, Rückgabetyp, Berechtigungen und weitere Deklarationen
stehen in `flow_contract`. Aussagekräftige Beschriftungen aus Studio Pro werden
als Methodennamen verwendet; allgemeine Beschriftungen werden durch Operation
und Ziel ersetzt. Ungültige Zeichen und reservierte Namen werden behandelt,
Namenskonflikte erhalten deterministische Suffixe.

```ruby
def main_line
  load_order
  decide '$Approved', if_true: :approve_order, if_false: :reject_order
  commit_order
  return_value '$Order'
end
```

Der Aufruf nach `decide` ist die gemeinsame Fortsetzung nach der Zusammenführung
der Zweige. Ein Zweig mit nur einer Aktivität verweist direkt auf deren Methode.
Leere Zweige und kurze Ausstiege können Lambdas verwenden:

```ruby
decide '$Skip', if_true: -> { return_value '-1' }, if_false: -> {}
loop_over :Orders, as: :Order, &step(:process_order)
call_microflow 'Sales.Summarize', as: :Summary, pass: { 'Sales.Summarize.Total' => '$Total' }
rescue_all rollback: true, &step(:handle_failure)
return_value '$Summary'
```

`step(:name)`, `step(method(:name))` und `step { ... }` binden Methoden oder kleine
Blöcke an den richtigen Builder eines Zweigs oder einer Schleife. Für mehrere
Fallwerte akzeptiert `decide` etwa `cases: [['ready', :process], ['new', :prepare]]`.
`branches:` akzeptiert weiterhin eine explizite Zuordnung. Einschränkungen für
`break_loop` und `continue_loop` bleiben auch über Methodengrenzen hinweg erhalten.
Regelentscheidungen behalten die Reihenfolge ihrer Argumente; Typentscheidungen
behalten die Typen und den Standardzweig.

Services registrieren ihre vollständig definierten Methoden mit
`flow :microflow, main: :main_line`; `:nanoflow` und `:rule` funktionieren ebenso.
Der Mendix-Export nutzt
`microflow :Name, plan: Class.new(Mxrb::Dsl::FlowProgram) { ... }`, sodass Definitionen
aus verschiedenen Dateien keine globalen Konstanten teilen. Auch `nanoflow` und
`rule` akzeptieren `plan:`.

Diese Methoden erzeugen das maßgebliche typisierte Modell beim Laden des
Ruby-Projekts. `Service#call` führt den resultierenden Graphen über die Ruby-Laufzeit
von MXRB aus. Zeichenketten wie `'$Approved'` sind Mendix-Ausdrücke; ein Ruby-Ausdruck
`if '$Approved'` wäre immer wahr und wird deshalb nicht erzeugt. `return_value`
und `end_flow` deklarieren Ausgänge des Flows. Ruby-`return` verlässt lediglich die
Methode, welche die Definition zusammensetzt.

Vorhandene Blockdeklarationen und `native` bleiben gültig. Ein Methodenplan und ein
Definitionsblock können nicht gleichzeitig angegeben werden. IDs, Referenzen und
Layout bleiben in den bisherigen Metadaten-Dateien. Tests vergleichen unveränderte
native Dokumente exakt und prüfen nach Änderungen das neue Ausführungsergebnis
sowie die Identität der Einheiten. Das neue Quellformat erweitert nicht die
unterstützten Graphformen; bisherige Diagnosen und Einschränkungen bleiben bestehen.

Eingebetteter Ruby-Anwendungscode wird bewahrt. Exportieren Sie vorhandene Modelle
in ein neues Verzeichnis, um den Stil zu erhalten, ohne ein bestehendes Ruby-Projekt
zu überschreiben. Die Tests `spec/method_flow_source_spec.rb` und
`spec/runtime/microflow_oracles_spec.rb` prüfen unter anderem Zusammenführungen,
frühe Ausstiege, Schleifen, Aufrufe, Rollback, Vererbung und isolierte Callbacks.
