# Estrutura do projeto exportado

**Português** · [English](../en-US/project-structure.md) · [Deutsch](../de-DE/project-structure.md)

`mxrb export` possui dois modos explícitos. `--mode mendix` é o padrão e mantém
a árvore Mendix em DSL por camadas. `--mode ruby` cria uma aplicação Ruby
convencional e executável com frontend React + Vite.

## Modo Mendix

```sh
bundle exec mxrb export App.mpr app-source --mode mendix
```

Essa árvore separa políticas globais, comportamento dos módulos, unidades
nativas preservadas e assets:

```text
project.rb
.mxrb/{native_units.json,native_units.rb,assets.json}
app/{security,navigation,design_system}/
modules/NomeDoModulo/{domain,application,presentation,infrastructure,security}/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` orquestra o carregamento. Os módulos contêm o comportamento. O
manifesto nativo preserva estruturas ainda sem DSL concisa; o manifesto de
assets registra caminho relativo, tamanho e SHA-256 de cada arquivo.

Na reconstrução, caminhos absolutos, traversal com `..`, arquivos ausentes e
checksums divergentes falham de forma segura. Somente entradas declaradas no
manifesto são gravadas.

A estrutura suporta Ruby para um Mendix novo, Ruby sobre baseline exportado,
Mendix para Ruby editável e Mendix → Ruby → Mendix estruturalmente equivalente.

## Modo Ruby

O modo Ruby também pode começar sem um projeto Mendix existente:

```sh
bundle exec mxrb init CustomerPortal --mode ruby
cd CustomerPortal
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

Esse comando cria diretamente a aplicação convencional com `app/models`,
`app/dtos`, `app/services`, `app/pages` e React + Vite. Um baseline Mendix
reversível fica isolado em `.mxrb`; ele não determina a organização do código
que será editado. Para materializar o projeto atual em um MPR:

```sh
bundle exec mxrb generate project.rb build/CustomerPortal.mpr
```

Models Ruby novos viram entidades, DTOs viram entidades non-persistent e as
declarações bidirecionais são sincronizadas no MPR. Código Ruby ou React sem
representação Mendix nativa permanece incorporado com checksum e reaparece
intacto no próximo export. A compilação falha explicitamente quando uma mudança
estrutural não pode ser representada, evitando conversão parcial silenciosa.

Para converter um MPR que já existe, use:

```sh
bundle exec mxrb export App.mpr app-ruby --mode ruby
```

```text
app/
  models/
  dtos/
  services/
  pages/
config/application.rb
frontend/
  package.json
  vite.config.js
  src/{main.jsx,App.jsx,app.css}
project.rb
.mxrb/
  ruby-app.json
  runtime/App.mpr
  mendix/
```

Entidades persistentes viram records. Entidades non-persistent viram classes
DTO e sempre usam o sufixo `_dto.rb`, evitando nomes ambíguos como `_2.rb`.
Services são classes Ruby comuns e inicialmente delegam ao interpretador nativo
em Ruby puro. Pages expõem metadados nativos ao frontend React.

Instale as dependências Ruby e do frontend uma vez e depois suba os dois
processos com um único comando:

```sh
bundle install
npm install --prefix frontend
bundle exec mxrb run .
```

`mxrb run` supervisiona a API JSON Ruby em loopback e o servidor Vite. O Vite
encaminha `/api` para Ruby. Use `--server-port` para a porta do backend e
`--client-port` para a porta do frontend. `--no-frontend` inicia somente a API.
Os nomes antigos `--api-port` e `--port` continuam como aliases compatíveis.
`--no-progress` é global e opcional; apenas oculta a saída de progresso.

Duas stacks opcionais adicionam convenções Ruby conhecidas sem alterar o modo
Ruby padrão:

```sh
bundle exec mxrb init ServiceDesk --mode ruby --flymetothemoon
bundle exec mxrb export App.mpr app-rails --mode ruby --onrails
```

`--flymetothemoon` adiciona Sinatra, Puma, ActiveRecord, Rake e RSpec.
`--onrails` adiciona Rails, Puma, ActiveRecord e RSpec. Ambas mantêm React +
Vite como frontend integrado da aplicação e usam o mesmo comando
`mxrb run .`. As migrations do ActiveRecord controlam apenas tabelas Ruby; o
manifesto MXRB continua autoritativo para o domain model Mendix e seus
round-trips.

## Diagrama do domain model no browser

Abra os domain models de um ou mais módulos Mendix em um diagrama ER inspirado
no DBeaver:

```sh
bundle exec mxrb diagram-er App.mpr --module Sales
bundle exec mxrb diagram-er App.mpr --module Sales --module Billing \
  --output build/App-layout.mpr
```

A barra lateral permite selecionar vários módulos ao mesmo tempo e mostra as
associações entre eles. A página também oferece busca de entidades,
posicionamento por drag-and-drop, zoom, ajuste à tela, auto-organização, grade,
visibilidade de atributos, rotas de relacionamento e pontos de origem/destino
arrastáveis. Entidades persistentes são azuis, DTOs/non-persistent amarelos e
OQL views verdes. **Salvar layout no MPR** grava as posições e os pontos das
associações locais nos campos Mendix nativos; âncoras cross-module, que não têm
campo BSON nativo, ficam em metadados visuais isolados do MXRB na mesma cópia
segura. A cópia padrão é `App.domain-layout.mpr`; para substituir uma saída
existente é necessário `--force`.

**Exportar PNG** baixa uma imagem em alta resolução dos módulos selecionados,
respeitando as cores, a exibição de atributos e as rotas. A exportação não modifica
o MPR; salve o layout separadamente quando as posições precisarem sobreviver ao
round-trip.

O modo direto continua disponível e ocupa o terminal até `Ctrl+C`. Para manter o
editor ER em segundo plano, use o lifecycle gerenciado, que preserva a cópia de
layout ao parar e nunca edita nem remove o MPR de origem:

```sh
bundle exec mxrb diagram-er up App.mpr --module Sales
bundle exec mxrb diagram-er status App.mpr
bundle exec mxrb diagram-er down App.mpr
bundle exec mxrb diagram-er up App.mpr       # retoma a mesma cópia
bundle exec mxrb diagram-er destroy App.mpr --yes
```

`destroy` para o servidor e remove somente a cópia e os conteúdos externos que
esse lifecycle criou. O controle usa um endpoint privado autenticado em loopback;
estado e token ficam em arquivos locais com permissões restritas.

A interface do editor é implementada em React + TypeScript e consome somente as
APIs do servidor Ruby. O bundle Vite é compilado em `lib/mxrb/web_ui`, incluído
na gem e servido localmente; portanto Node.js não é necessário para usar o
editor instalado e nenhum CDN é acessado. Para desenvolver a interface, use
`npm install`, `npm run typecheck` e `npm run build` em `frontend/modeler`.

## Diagramas UML

UML é uma implementação adicional e independente do editor ER. Ela usa a porta
4569 e não altera o layout do domain model. O viewer reúne diagramas de classe,
atividade de microflows e sequência de chamadas, renderizados com Mermaid:

```sh
bundle exec mxrb uml App.mpr
bundle exec mxrb uml App.mpr --export=class --module Sales
bundle exec mxrb uml App.mpr --export=activity \
  --microflow=Sales.CreateOrder --format=plantuml
bundle exec mxrb uml App.mpr --export=sequence \
  --root=Sales.CreateOrder --depth=3
bundle exec mxrb uml App.mpr --export=sequence --module=Sales
```

Sem `--export`, o comando abre o viewer unificado em
`http://127.0.0.1:4569`. A exportação textual usa Mermaid por padrão; selecione
PlantUML com `--format=plantuml`. Diagramas de sequência aceitam uma raiz com
profundidade limitada ou todas as chamadas internas de um módulo. O viewer usa
o mesmo workspace React + TypeScript; Mermaid é empacotado localmente para que a
renderização também funcione offline.

## Transições de versão e round-trips

Os dois modos mantêm IDs estáveis do Mendix e o baseline nativo completo usado
em upgrades, downgrades e round-trips repetidos. No modo Ruby, declarações de
models/DTOs são compiladas de volta no MPR. Os corpos Ruby dos services e os
fontes React são armazenados com SHA-256 em uma tabela MXRB dentro do MPR; uma
nova exportação `--mode ruby` restaura exatamente os arquivos editados.

O comportamento Mendix nativo continua autoritativo para construções que ainda
não possuem compilador semântico Ruby → Mendix. O manifesto de cobertura deixa
esse estado explícito em vez de alegar uma conversão silenciosa. O código
Ruby/React preservado sobrevive ao round-trip mesmo sem representação direta no
Studio Pro.

[Voltar ao índice](README.md)
