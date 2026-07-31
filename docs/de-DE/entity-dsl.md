# Entitäten-DSL

[Português](../pt-BR/entity-dsl.md) · [English](../en-US/entity-dsl.md) · **Deutsch**

Mit `mxrb entity new Modul.Entitaet` erzeugte Dateien werden im Modulblock
ausgewertet. Deshalb wird nur der lokale Name deklariert:

```ruby
entity :Animal do
  documentation "Tier in der Klinik"
  string :Name, default: "", documentation: "Anzeigename"
  integer :Age, default: 0
  long :ExternalId
  float :Weight
  decimal :Balance
  boolean :Active, default: true
  datetime :BirthDate
  autonumber :Sequence
  hashstring :PasswordHash
  binary :Document
  enum :Species, enumeration: "VetClinic.AnimalSpecies"
end
```

Verfügbare Typen sind `string`, `integer`, `long`, `float`, `decimal`,
`boolean`, `datetime`, `autonumber`, `hashstring`, `binary` und `enum`. Derzeit
werden `default:`, `documentation:` und bei Enum-Attributen `enumeration:` in
das MPR geschrieben. Die Enumeration selbst wird mit `enumeration` deklariert,
das Attribut mit `enum`.

## Assoziationen

```ruby
association "VetClinic.Owner", name: "Animal_Owner" # N:1 Reference
association "VetClinic.Passport", name: "Animal_Passport", owner: :Both # 1:1
association "VetClinic.Tag", name: "Animal_Tags", type: :ReferenceSet # N:N
association "VetClinic.Group", name: "Animal_Groups",
            type: :ReferenceSet, owner: :Both
```

Das erste Argument ist das qualifizierte Ziel. `type:` akzeptiert `:Reference`
(Standard) oder `:ReferenceSet`; `owner:` akzeptiert `:Default` oder `:Both`.

## Persistenz, Ereignisse und Zugriff

`non_persistent!` erzeugt eine nicht persistente Entität. Verfügbare Hooks sind
`before_commit`, `after_commit`, `before_delete` und `after_delete`, jeweils mit
`microflow:`. `access_rule` akzeptiert qualifizierte Rollen sowie `create:`,
`delete:`, `read:`, `write:` und `xpath:`. Lesen und Schreiben verwenden
`:all`, `:none` oder eine Attributliste.

Weitere CLI-Hilfe liefert `mxrb entity --help`; das Ergebnis wird mit
`mxrb generate project.rb` und `mxrb validate App.mpr` geprüft.
