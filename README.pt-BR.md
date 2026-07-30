# MXRB

[English](README.md) · **Português** · [Deutsch](README.de-DE.md)

MXRB é uma ferramenta Ruby-first para ler, escrever, exportar, validar e testar
projetos Mendix (`.mpr`) sem MDL ou `mxcli`.

## Capacidades

- leitura e escrita profunda de MPR v1/v2;
- exportação de projetos para Ruby editável;
- geração idempotente por DSL Ruby;
- edição profunda em Ruby de toda unit nativa, com baseline sem perdas;
- comparação, diff semântico, referências e análise de impacto;
- renomeação segura com prévia;
- movimentação de units entre pastas do mesmo módulo com prévia;
- remoção de units independentes com verificação de referências e filhos;
- lint e avaliações executáveis de modelo;
- descoberta de OQL nativo e visão SQL lógica somente quando o projeto contém OQL;
- PostgreSQL isolado e sincronizado pelo Runtime para consultas SQL diretas;
- testes funcionais de microflows localmente ou em Docker.
- busca e instalação de módulos Ruby reutilizáveis com SHA-256 travado.

A matriz preserva estruturalmente projetos Mendix 5.21–11.12. A validação
nativa exata do Mendix 5 ainda depende de Windows/Studio Pro e é uma limitação
explícita do MXRB; ela não faz parte do gate automatizado direto.

## Requisitos

Ruby 4.0+, SQLite3 e, para gates oficiais, o toolchain Mendix exato. O modo
local precisa do Java compatível; o modo Docker fornece JDK e Runtime.

```sh
bundle install
bundle exec mxrb validate App.mpr
bundle exec mxrb export App.mpr app-ruby
bundle exec mxrb compare original.mpr reconstruido.mpr
bundle exec mxrb module search
bundle exec mxrb module add shared-kernel
bundle exec mxrb cache status App.mpr
bundle exec mxrb cache warm App.mpr
bundle exec mxrb cache clear App.mpr
bundle exec mxrb oql App.mpr --dialect postgresql
bundle exec mxrb db up App.mpr
bundle exec mxrb db sql App.mpr 'SELECT * FROM "sales$order" LIMIT 20'
```

O MPR armazena o modelo, não os dados da aplicação. `db up` compila o Runtime
portátil exato e permite que ele sincronize um volume PostgreSQL isolado. O
acesso é restrito a loopback e usa um papel somente leitura, salvo quando
`--write` é solicitado explicitamente. Consulte
[OQL e acesso SQL local](docs/pt-BR/oql-sql.md).

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
As asserções cobrem retorno do microflow e estado persistido por contagens
de entidade/XPath.

## Desenvolvimento

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
bundle exec ruby script/branch_report.rb
bundle exec rubocop
```

A suíte exige 100% de cobertura de linhas e branches. O relatório de branches
lista qualquer regressão por arquivo e linha.

Consulte a [documentação completa em português](docs/pt-BR/README.md).

## Licença

MIT.
