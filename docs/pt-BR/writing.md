# Criação e edição de projetos

**Português** · [English](../en-US/writing.md) · [Deutsch](../de-DE/writing.md)

`mxrb generate` avalia uma definição Ruby e cria ou atualiza o MPR. Nomes
Mendix são chaves estáveis, portanto reaplicar a definição não duplica units.

Para iniciar em uma pasta vazia:

```sh
mxrb init vet_clinic
cd vet_clinic
bundle install
bundle exec mxrb generate project.rb
bundle exec mxrb validate VetClinic.mpr
```

`init` aceita snake_case ou PascalCase, cria `Gemfile`, `project.rb` e o módulo
principal em `modules/VetClinic`. O scaffold inclui somente código próprio: o
módulo `System` é implícito no Runtime; Administration e Atlas são módulos de
marketplace. O comando aborta sem alterar nada quando o diretório já existe.

Para adicionar outro módulo de aplicação a partir da raiz do projeto:

```sh
mxrb module new appointments
```

O comando cria `modules/Appointments`, reutiliza o mesmo scaffold de
domain/application e conecta o `module.rb` no `project.rb`. A operação aborta
atomicamente se o módulo já existir ou se o arquivo de projeto não puder ser
atualizado. Use `--target DIR` ao executar fora da raiz do projeto.

Os scaffolds de artefatos, apresentação, infraestrutura, testes, design e CI
estão no [catálogo de scaffolds](scaffolds.md). Para entidades, consulte a
[referência completa da DSL](entity-dsl.md).

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"
  self.module :Sales do
    entity :Order do
      string :Number, documentation: "Número estável do pedido"
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
microflow "cria pedido",
          call: "Sales.ACT_CreateOrder",
          before: { call: "Sales.TEST_Preparar" },
          after: { call: "Sales.TEST_Limpar" },
          expect: {
            return: "true",
            count: { entity: "Sales.Order", xpath: "[Status = 'Open']", equals: 1 }
          }
```

Use `mxrb test App.mpr functional_test.rb`; acrescente `--docker` para executar
JDK, MxBuild e Runtime em containers descartáveis. Não há JUnit nem MDL. O MPR
original nunca é alterado.
Use `--json resultado.json` e/ou `--junit resultado.xml` para relatórios de CI.
JUnit é apenas o formato XML de intercâmbio neste caso; o MXRB o grava
diretamente em Ruby, sem instalar ou executar o framework Java JUnit.

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

`mxrb export` grava `.mxrb/native_units.json` como baseline sem perdas e
`.mxrb/native_units.rb` com cada payload BSON expandido em Hashes Ruby
editáveis. Entradas `native_unit` expõem todos os campos de imagens, constantes,
datasets, serviços, configurações, templates e tipos futuros; valores binários
usam `bson_binary`. Alterações nesse Ruby sobrepõem o baseline antes das escritas
tipadas. Corpos de flow possuem `body_fingerprint`: o grafo nativo é reutilizado
quando o Ruby não mudou e regenerado após uma edição.

A DSL cobre criação/alteração/retrieve/commit/delete, chamadas de microflow,
Java, JavaScript, nanoflow e app service, páginas, REST, listas, decisões,
loops, eventos de erro e rescue.

## Páginas, navegação e segurança

Controles core possuem métodos concisos: `text`, `text_box`, `number_input`,
`text_area`, `check_box`, `date_picker`, `button`, `container`, `snippet` e
`tab_control` com widgets dentro de cada `tab_page`. Esses controles usam o
modelo Forms moderno do Mendix 11. `data_grid` gera Data Grid 2; `drop_down` e
`reference_selector` geram Combo Box.

Widgets pluggable precisam dos `.mpk` em `widgets/`. Depois de instalar os
pacotes, sincronize o schema específico da versão e aplique as propriedades
Ruby com:

```bash
bundle exec mxrb widgets sync project.rb MeuApp.mpr
```

Para outros MPKs existe `pluggable_widget`, com widget id e mapa de
propriedades. Widgets importados ainda desconhecidos são preservados como
`native_widget` e `deep_structure`, sem perder configuração no ciclo
export/generate. Toda página importada também expõe `deep_structure({...})`.
Menus combinam DSL curta e estrutura profunda.
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
project.plan_remove("Sales.FluxoSemUso")
project.plan_move("Sales.Processar", to: "Sales.Automacao")
project.analyze
```

Na CLI, use `refs`, `callers`, `callees`, `impact`, `rename`, `remove`, `move`,
`lint`, `report`, `diff`, `find`, `describe` e `tree`. O lint nativo verifica
acesso de entidades persistentes, papéis de páginas/flows, documentação de
contratos públicos, alvos de navegação e mapeamentos duplicados de module role.
Use `mxrb cache status|warm|clear app.mpr` para métricas e manutenção do índice.
Refatorações apenas
mostram a prévia, salvo quando `--apply` é informado. A remoção é bloqueada se
houver referências recebidas ou units filhas; movimentos ficam no mesmo
módulo e rejeitam ciclos de pastas.
