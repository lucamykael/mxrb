# DSL de entidades

**Português** · [English](../en-US/entity-dsl.md) · [Deutsch](../de-DE/entity-dsl.md)

Arquivos criados por `mxrb entity new Modulo.Entidade` são avaliados dentro do
bloco do módulo. Por isso, a declaração usa somente o nome local:

```ruby
entity :Animal do
  documentation "Animal atendido pela clínica"
  string :Name, default: "", documentation: "Nome de exibição"
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

Os tipos disponíveis são `string`, `integer`, `long`, `float`, `decimal`,
`boolean`, `datetime`, `autonumber`, `hashstring`, `binary` e `enum`. As opções
gravadas atualmente são `default:`, `documentation:` e, para `enum`,
`enumeration:`. A enumeração é declarada separadamente com `enumeration`; um
atributo de enum usa `enum`, não `enumeration`.

```ruby
enumeration :AnimalSpecies do
  value :Dog, caption: "Dog"
  value :Cat, caption: "Cat"
end
```

## Associações

O primeiro argumento é a entidade de destino qualificada. `name:` define o
nome estável da associação.

```ruby
entity :Animal do
  # Reference padrão: vários Animal podem apontar para um Owner (N:1).
  association "VetClinic.Owner", name: "Animal_Owner"

  # Reference 1:1: ambos os lados são proprietários da associação.
  association "VetClinic.Passport", name: "Animal_Passport", owner: :Both

  # ReferenceSet: muitos para muitos (N:N).
  association "VetClinic.Tag", name: "Animal_Tags", type: :ReferenceSet

  # ReferenceSet com propriedade em ambos os lados.
  association "VetClinic.Group", name: "Animal_Groups",
              type: :ReferenceSet, owner: :Both
end
```

`type:` aceita `:Reference` (padrão) ou `:ReferenceSet`; `owner:` aceita
`:Default` (padrão) ou `:Both`.

## Persistência, eventos e acesso

```ruby
entity :AnimalSearchResult do
  non_persistent!
  string :Name
end

entity :Animal do
  before_commit microflow: "VetClinic.VAL_Animal"
  after_commit microflow: "VetClinic.ACT_AfterAnimalCommit"
  before_delete microflow: "VetClinic.VAL_DeleteAnimal"
  after_delete microflow: "VetClinic.ACT_AfterAnimalDelete"

  access_rule "VetClinic.User",
              create: true,
              delete: false,
              read: :all,
              write: %i[Name BirthDate],
              xpath: "[Active = true()]"
end
```

Em `access_rule`, `read:` e `write:` aceitam `:all`, `:none` ou uma lista de
atributos. Declare um ou mais papéis qualificados como primeiros argumentos.

Use `mxrb entity --help` para o comando e `mxrb generate project.rb` seguido de
`mxrb validate App.mpr` para validar o resultado.
