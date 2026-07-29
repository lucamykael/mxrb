# Criação e edição de projetos

**Português** · [English](../en-US/writing.md) · [Deutsch](../de-DE/writing.md)

`mxrb generate` avalia uma definição Ruby e cria ou atualiza o MPR. Nomes
Mendix são chaves estáveis, portanto reaplicar a definição não duplica units.

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

```sh
bundle exec mxrb generate shop.rb
bundle exec mxrb validate Shop.mpr
bundle exec mxrb export Shop.mpr exported-shop
bundle exec mxrb compare original.mpr rebuilt.mpr
```

## Avaliações de modelo

```ruby
artifact "Sales.Order", kind: :entity
no_call_cycles
no_missing_internal_references
check("Order possui Total") do |project|
  project.find_artifact("Sales.Order.Total", kind: :attribute)
end
```

Execute com `mxrb evaluate App.mpr evaluation.rb`.

## Testes funcionais

```ruby
microflow "cria pedido", call: "Sales.ACT_CreateOrder"
```

Use `mxrb test App.mpr functional_test.rb`; acrescente `--docker` para executar
JDK, MxBuild e Runtime em containers descartáveis. Não há JUnit nem MDL. O MPR
original nunca é alterado.

## Cobertura

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
```

## Marketplace de módulos Ruby

```sh
mxrb module search
mxrb module search security
mxrb module add shared-kernel
mxrb module add ./pacote-local --target ./projeto-exportado
```

Catálogos JSON podem vir da gem, de um caminho local ou de HTTPS com
`--registry`. Pacotes possuem `mxrb-module.json` e podem ser embutidos,
diretórios locais ou repositórios Git. A instalação usa staging, rejeita
caminhos inseguros e grava `.mxrb/modules.lock.json` com versão, origem, ref e
SHA-256 dos arquivos instalados.

## Baseline nativo e estruturas profundas

`mxrb export` grava `.mxrb/native_units.json`. Units fora da DSL concisa são
preservadas integralmente. Corpos de flow possuem `body_fingerprint`: o grafo
nativo é reutilizado quando o Ruby não mudou e regenerado após uma edição.

A DSL cobre criação/alteração/retrieve/commit/delete, chamadas de microflow,
Java, JavaScript, nanoflow e app service, páginas, REST, listas, decisões,
loops, eventos de erro e rescue.

## Páginas, navegação e segurança

Controles core possuem métodos concisos; toda página importada também expõe
`deep_structure({...})`. Menus combinam DSL curta e estrutura profunda.
Project roles, module roles e `allowed_roles` são editáveis em Ruby.

## MPR v2

O manifesto registra `format_version: v2`; a geração cria automaticamente os
arquivos `mprcontents/*.mxunit`.

## Análise semântica

```ruby
project.references_to("Sales.Order")
project.callers_of("Sales.Process")
project.impact_of("Sales.Order")
project.plan_rename("Sales.Order", to: "Invoice")
project.analyze
```

Na CLI, use `refs`, `callers`, `callees`, `impact`, `rename`, `lint`, `report`,
`diff`, `find`, `describe` e `tree`. Renomeações apenas mostram a prévia, salvo
quando `--apply` é informado.
