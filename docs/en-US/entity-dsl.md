# Entity DSL

[Português](../pt-BR/entity-dsl.md) · **English** · [Deutsch](../de-DE/entity-dsl.md)

Files created by `mxrb entity new Module.Entity` are evaluated inside the
module block, so declarations use the local name:

```ruby
entity :Animal do
  documentation "Animal cared for by the clinic"
  string :Name, default: "", documentation: "Display name"
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

Available types are `string`, `integer`, `long`, `float`, `decimal`, `boolean`,
`datetime`, `autonumber`, `hashstring`, `binary`, and `enum`. Options currently
written to the MPR are `default:`, `documentation:`, and `enumeration:` for enum
attributes. Declare the enumeration separately with `enumeration`; use `enum`
for an entity attribute.

## Associations

```ruby
association "VetClinic.Owner", name: "Animal_Owner" # N:1 Reference
association "VetClinic.Passport", name: "Animal_Passport", owner: :Both # 1:1
association "VetClinic.Tag", name: "Animal_Tags", type: :ReferenceSet # N:N
association "VetClinic.Group", name: "Animal_Groups",
            type: :ReferenceSet, owner: :Both
```

The first argument is the qualified target. `type:` accepts `:Reference`
(default) or `:ReferenceSet`; `owner:` accepts `:Default` or `:Both`.

## Persistence, events, and access

Use `non_persistent!` for a non-persistable entity. Lifecycle hooks are
`before_commit`, `after_commit`, `before_delete`, and `after_delete`, each with
`microflow:`. Access rules accept qualified roles plus `create:`, `delete:`,
`read:`, `write:`, and `xpath:`; read/write accept `:all`, `:none`, or an
attribute list.

Run `mxrb entity --help`, then validate generated output with
`mxrb generate project.rb` and `mxrb validate App.mpr`.
