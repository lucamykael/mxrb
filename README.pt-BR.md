# MXRB

[English](README.md) · **Português** · [Deutsch](README.de-DE.md)

MXRB é uma ferramenta Ruby-first para ler, escrever, exportar, validar e testar
projetos Mendix (`.mpr`) sem MDL ou `mxcli`.

## Capacidades

- leitura e escrita profunda de MPR v1/v2;
- exportação de projetos para Ruby editável;
- geração idempotente por DSL Ruby;
- preservação de units nativas ainda sem abstração concisa;
- comparação, diff semântico, referências e análise de impacto;
- renomeação segura com prévia;
- lint e avaliações executáveis de modelo;
- testes funcionais de microflows localmente ou em Docker.

## Requisitos

Ruby 4.0+, SQLite3 e, para gates oficiais, o toolchain Mendix exato. O modo
local precisa do Java compatível; o modo Docker fornece JDK e Runtime.

```sh
bundle install
bundle exec mxrb validate App.mpr
bundle exec mxrb export App.mpr app-ruby
bundle exec mxrb compare original.mpr reconstruido.mpr
```

## Ruby DSL

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"
  self.module :Sales do
    entity :Order do
      string :Number, required: true
      decimal :Total, default: 0
    end
  end
end
```

## Avaliações e testes funcionais

```ruby
artifact "Sales.Order", kind: :entity
no_call_cycles
no_missing_internal_references
```

```ruby
microflow "cria pedido", call: "Sales.ACT_CreateOrder"
```

```sh
bundle exec mxrb evaluate Shop.mpr evaluation.rb
bundle exec mxrb test Shop.mpr functional_test.rb --docker
```

Não há JUnit ou MDL. A instrumentação, o pacote, o banco e os uploads existem
somente na cópia descartável; o projeto original não é alterado.

## Desenvolvimento

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
```

A suíte exige 100% de cobertura de linhas. A cobertura de branches é reportada
separadamente.

Consulte a [documentação completa em português](docs/pt-BR/README.md).

## Licença

MIT.
