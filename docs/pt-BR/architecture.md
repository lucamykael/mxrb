# Arquitetura de projetos Mendix no mxrb

**Português** · [English](../en-US/architecture.md) · [Deutsch](../de-DE/architecture.md)

Este documento define a estrutura canônica de um projeto editável pelo `mxrb`.
Ela tem dois objetivos igualmente importantes:

1. permitir escrever o projeto em Ruby e gerar um `.mpr`;
2. exportar um `.mpr` existente para Ruby, editar e gerar Mendix novamente.

O Ruby é uma representação versionável do metamodelo Mendix. Ele não é uma
segunda aplicação executada em paralelo ao runtime Mendix.

As regras normativas de classificação de microflows, nanoflows, security,
navigation e design system estão em
[padrão arquitetural](architectural-standard.md).

## Princípios de compatibilidade com Mendix

Um app Mendix é uma árvore de **units**. O app é a raiz; módulos e pastas são
units estruturais; Domain Models, páginas e microflows são units de modelo.
Cada módulo possui exatamente um Domain Model, além de seus documentos e
configurações.

Por isso, a principal fronteira arquitetural do `mxrb` também é o **módulo**.
Um módulo deve representar uma capacidade de negócio ou integração substituível,
por exemplo `CustomerManagement`, `OrderManagement` ou `PaymentIntegration`.

Referências:

- [App Explorer](https://docs.mendix.com/refguide/app-explorer/)
- [Modules](https://docs.mendix.com/refguide/modules/)
- [Mendix Metamodel](https://docs.mendix.com/apidocs-mxsdk/mxsdk/mendix-metamodel/)
- [Naming Convention Best Practices](https://docs.mendix.com/refguide/naming-convention-best-practices/)

## Estrutura canônica

```text
meu_app/
├── project.rb
├── modules/
│   ├── CustomerManagement/
│   │   ├── module.rb
│   │   ├── domain/
│   │   │   ├── model.rb
│   │   │   └── entities/
│   │   │       ├── customer.rb
│   │   │       └── order.rb
│   │   ├── application/
│   │   │   ├── application.rb
│   │   │   └── microflows/
│   │   │       └── create_order.rb
│   │   ├── presentation/
│   │   │   ├── presentation.rb
│   │   │   └── pages/
│   │   │       └── order_list.rb
│   │   └── infrastructure/
│   │       └── .keep
│   └── OrderManagement/
│       └── ...
├── resources/                 # arquivos externos ao metamodelo, quando houver
├── themesource/               # estrutura nativa do tema Mendix
├── widgets/                   # widgets pluggable nativos
└── vendor/                    # módulos/artefatos externos, não editados pelo domínio
```

Arquivos como `themesource/`, `widgets/`, `javasource/`, `deployment/` e
`resources/` devem manter os nomes e formatos esperados pelo Mendix. O `mxrb`
não deve esconder ou renomear esses diretórios.

## Mapeamento para Clean Architecture

### `domain/`

Contém o Domain Model do módulo:

- entidades;
- atributos;
- associações;
- enumerações;
- regras de domínio puras, quando suportadas.

O domínio não deve depender de páginas, serviços externos ou detalhes de
infraestrutura. Uma entidade deve ter nome singular em PascalCase, como
`Customer` ou `PurchaseOrder`.

`domain/` representa o único Domain Model permitido pelo módulo Mendix.
`domain/model.rb` é somente o agregador; cada entidade fica em seu próprio
arquivo dentro de `domain/entities/`. Associações ficam no arquivo da entidade
que possui a referência.

```ruby
# domain/model.rb
evaluate File.join(__dir__, "entities", "customer.rb")
evaluate File.join(__dir__, "entities", "order.rb")
```

```ruby
# domain/entities/order.rb
entity :Order do
  decimal :Total, default: 0
  association "Sales.Customer", name: "Order_Customer"
end
```

A cardinalidade segue o modelo de tipo/proprietário do Mendix:

```ruby
# 1:N (padrão): Reference + Default
association "Sales.Customer", name: "Order_Customer"

# 1:1: Reference + Both
association "Sales.Profile", name: "Customer_Profile", owner: :Both

# N:N: ReferenceSet + Default
association "Sales.Tag", name: "Order_Tags", type: :ReferenceSet
```

### `application/`

Contém casos de uso e coordenação:

- microflows;
- nanoflows;
- regras de aplicação;
- scheduled events;
- task queues.

Convenções úteis para microflows:

- `ACT_`: operação de negócio reutilizável;
- `VAL_`: validação;
- `DS_`: data source;
- `SUB_`: submicroflow interno;
- `IVK_`: ação invocada pela interface;
- `API_`: operação exposta como contrato.

Esses prefixos são uma convenção do projeto, não uma exigência do formato MPR.

Cada microflow fica em `application/microflows/<nome>.rb`.
`application/application.rb` é somente o agregador desses arquivos.

### `presentation/`

Contém a interface:

- páginas;
- layouts;
- snippets;
- menus;
- recursos de navegação específicos do módulo.

A apresentação pode chamar casos de uso em `application/`, mas não deve
implementar regras centrais de negócio.

Cada página fica em `presentation/pages/<nome>.rb`.
`presentation/presentation.rb` é somente o agregador.

### `infrastructure/`

Contém adaptadores e detalhes externos:

- consumed/published REST, OData, GraphQL e SOAP;
- import/export mappings;
- message definitions;
- Java e JavaScript actions;
- persistência ou conectores externos;
- constantes técnicas.

Microflows de infraestrutura devem ser chamados pela camada de aplicação. O
domínio não deve depender diretamente deles.

## Regra de dependências

```text
presentation ──────┐
                   ├──> application ───> domain
infrastructure ────┘
```

- `domain` não conhece nenhuma outra camada.
- `application` conhece o domínio e contratos necessários.
- `presentation` chama a aplicação.
- `infrastructure` implementa integrações usadas pela aplicação.
- dependências entre módulos devem passar por operações públicas documentadas,
  evitando acesso disperso aos detalhes internos de outro módulo.

O Mendix não aplica essas restrições automaticamente; o `mxrb lint` deverá
validá-las em uma etapa futura.

## Arquivo raiz

`project.rb` monta o app e pode ser executado diretamente pelo comando
`mxrb generate`:

```ruby
require "mxrb"

output = ENV.fetch("MXRB_OUTPUT_PATH", File.join(__dir__, "MyApp.mpr"))

Mxrb.define(output) do
  mendix_version "10.17.0"
  evaluate File.join(__dir__, "modules", "CustomerManagement", "module.rb")
  evaluate File.join(__dir__, "modules", "OrderManagement", "module.rb")
end
```

Cada `module.rb` abre uma única definição de módulo:

```ruby
self.module :OrderManagement do
  evaluate File.join(__dir__, "domain", "model.rb")
  evaluate File.join(__dir__, "application", "application.rb")
  evaluate File.join(__dir__, "presentation", "presentation.rb")
end
```

## Fluxo Ruby para Mendix

```sh
bundle exec mxrb generate meu_app/project.rb build/MyApp.mpr
```

O writer usa nomes como chave estável ao atualizar módulos, entidades,
atributos, associações e documentos. Reaplicar a mesma fonte Ruby não deve
duplicar artefatos.

Para projetos reais, mantenha o `.mpr` e o diretório `mprcontents/` juntos. Em
MPR v2, ambos formam o projeto.

## Fluxo Mendix para Ruby

```sh
bundle exec mxrb export MyApp.mpr meu_app/
```

O exportador cria:

- `project.rb`;
- um diretório por módulo;
- `domain/model.rb` como agregador;
- `domain/entities/*.rb`, um arquivo por entidade;
- `application/application.rb` e um arquivo por microflow;
- `presentation/presentation.rb` e um arquivo por página;
- o espaço reservado de `infrastructure/`.

Depois da exportação:

```sh
bundle exec mxrb generate meu_app/project.rb build/MyApp.mpr
```

Esse round-trip preserva o metamodelo conhecido pelo `mxrb`. Flows dos fixtures
públicos são DSL tipada; páginas/widgets avançados usam um hash Ruby profundo e
editável. Units fora dessas superfícies usam o manifesto nativo como baseline
lossless até ganharem uma representação Ruby própria.

## Estratégia segura de round-trip

Há dois modos de trabalho:

### Atualização preservadora

Exporte um MPR, edite o Ruby e gere sobre uma cópia do MPR original. Esse é o
modo recomendado porque units ainda desconhecidas pelo `mxrb` continuam no
arquivo.

```sh
cp MyApp.mpr work/MyApp.mpr
cp -R mprcontents work/mprcontents   # somente para MPR v2
bundle exec mxrb generate meu_app/project.rb work/MyApp.mpr
```

### Reconstrução

Gere um MPR novo a partir do Ruby. Use apenas quando todos os artefatos
necessários estiverem representados pelo DSL. Neste estágio, configurações
globais, segurança completa, widgets complexos, integrações e alguns tipos de
documento ainda não são reconstruídos integralmente.

## Convenções de nomes

- módulos: `UpperCamelCase`, descrevendo responsabilidade;
- entidades: singular e `PascalCase`;
- atributos: `PascalCase`;
- detalhes técnicos de entidade: prefixo `_`;
- associações: padrão Mendix `Origem_Destino`;
- nomes públicos devem ser estáveis, pois o Mendix usa nomes para reconciliar
  vários artefatos durante substituições e atualizações.

## Fonte de verdade

Escolha uma fonte de verdade por branch de trabalho:

- **Ruby-first**: Ruby é editado; o MPR é artefato gerado/atualizado.
- **Mendix-first**: Studio Pro é editado; execute `mxrb export` antes de alterar
  o Ruby.

Não edite simultaneamente os mesmos artefatos nos dois lados. O fluxo futuro de
`mxrb diff` deverá detectar divergências antes da conversão.
