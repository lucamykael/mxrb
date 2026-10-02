# Portabilidade real entre Ruby, TypeScript e Mendix

## Direção principal: Mendix → Ruby + React/TypeScript

O objetivo da conversão é uma aplicação com backend e regras em Ruby e frontend
web editável em React/TypeScript, sem executar o runtime Mendix. Retornar ao MPR
é um contrato adicional, não o critério de autonomia da aplicação Ruby.
`runtime_only` não significa fonte opaco: código Ruby e rotas React próprios
podem ser integralmente editáveis mesmo sem projeção de volta ao Studio Pro.
Por isso, `portability --require-native` verifica a direção Ruby → Mendix;
ele **não** certifica a conclusão de Mendix → Ruby.

O runtime Ruby ainda abre uma cópia interna do MPR para metadados e execução
dos grafos que dependem dela. Não confundir “sem JVM/runtime Mendix” com
“sem baseline MPR”. Variantes não traduzidas, custom actions sem adapter e
widgets sem implementação web continuam sendo lacunas de conversão, não
funcionalidades concluídas por estarem preservadas.

### Campos e Data Views editáveis

A exportação expõe no Ruby da página a editabilidade do campo, condição,
estilo somente leitura, placeholder, senha, limite de tamanho, rótulo acessível,
obrigatoriedade ARIA, tabulação e autocomplete. Alterar essas opções em
`app/pages/**/*.rb` muda a projeção servida pelo backend Ruby; não exige
recompilar um MPR. A apresentação React aplica as opções suportadas.

Data Views propagam o bloqueio de edição aos campos, inclusive em views
aninhadas. Condições booleanas de expressão são avaliadas com tipos, parênteses,
precedência e strings literais, sem `eval`. Condições desconhecidas ou ainda
opacas não liberam edição. Regras baseadas em roles/condições nativas adicionais
ainda exigem tradução; esse bloqueio conservador não conta como equivalência.
As regras de autorização do backend continuam independentes desse controle UI.

Eventos de foco, alteração e saída recebem o objeto atualizado; alteração e
saída aguardam a gravação. Respostas da API não remontam o campo nem removem
seu foco. Objetos vindos do servidor permanecem persistentes; falhas de gravação,
inclusive 404, são exibidas em vez de simular sucesso local.

`listen_to` acompanha a seleção da grade nomeada na página, sem confundir a
seleção de outra grade. Fontes por associação percorrem cada etapa usando o
objeto anterior e param em ligações vazias, sem consultar toda a entidade.

O fixture `spec/fixtures/ruby_frontend_editability/project.rb` e o cenário
`spec/fixtures/frontend_browser/ruby_editability_flow.json` verificam edição
condicional, seleção e persistência após recarregar, usando somente Ruby e
React. Testes de componente cobrem escrita rejeitada, foco, eventos, condições
e associações com múltiplas etapas. Isso fecha esse recorte, não toda a matriz
de frontend nem todas as dependências do baseline.

## O que o MXRB garante

O modo Ruby possui três classes explícitas de portabilidade:

- `native`: a declaração Ruby é materializada como documento editável no MPR;
- `preserved_native`: o documento Mendix original permanece no sidecar reversível;
- `runtime_only`: o código funciona no runtime Ruby/TypeScript do MXRB, mas não
  se torna sozinho uma página ou fluxo nativo do Studio Pro.

Audite um projeto antes de entregá-lo:

```bash
bundle exec mxrb portability .
bundle exec mxrb portability . --json
bundle exec mxrb portability . --require-native
```

`--require-native` termina com código diferente de zero quando existe código que
depende do runtime MXRB. Isso impede usar “round-trip sem perda” como sinônimo
incorreto de “todo o código virou documento Mendix”.

Entidades, atributos e validações `required`/`unique` declarados em Ruby voltam
ao domínio Mendix. O contrato inclui documentação, valor padrão, tamanho de
string, localização de data, referência de enumeração e associações locais ou
cross-module. Associações incluem tipo, owner, storage format, documentação,
delete behavior e identidade nativa estável. Microflows e nanoflows
com grafo coberto pelo DSL são exportados automaticamente com bloco `native` e
`body_fingerprint`; ao editar o corpo Ruby, a recompilação atualiza o documento
Mendix. Grafos ainda não mapeados ficam intactos no sidecar e aparecem como
`runtime_only`.

Novas páginas que precisam existir no Studio Pro devem usar `Page.native`. Uma
rota React manual continua sendo uma rota React — o relatório não a promove
artificialmente a página Mendix.

A matriz por superfície, com a diferença entre leitura, preservação e edição,
está em [Cobertura Ruby nativa](cobertura-ruby-nativa.md).

## TypeScript que roda dentro do Mendix

Para um componente React/TypeScript tornar-se um artefato Mendix, desenvolva-o
como pluggable widget oficial:

```bash
mkdir -p widgets-src
bundle exec mxrb widgets new OrderSummary widgets-src
cd widgets-src/OrderSummary
npm start

cd "$PROJECT_ROOT"
bundle exec mxrb widgets build widgets-src/OrderSummary \
  --project "$PROJECT_ROOT"
bundle exec mxrb widgets sync project.rb build/App.mpr
```

O comando `new` chama o gerador oficial fixado
`@mendix/generator-widget@11.11.0`. `build` executa `npm ci` e `npm run release`;
o resultado é um `.mpk`, o formato oficial descoberto pelo Studio Pro na pasta
`widgets`. O `widgets sync` existente lê o schema do MPK e sincroniza as
propriedades no MPR.

O MXRB falha antes de escrever quando a DSL concisa tenta levar toolbar ou
`on_change` do fallback de Data Grid 2 ao schema oficial: essas formas não são
estruturalmente equivalentes. Use botões core explícitos para chamar microflows
ou nanoflows, ou implemente a interação no próprio pluggable widget.

Referências oficiais:

- <https://docs.mendix.com/apidocs-mxsdk/apidocs/pluggable-widgets/>
- <https://www.npmjs.com/package/@mendix/generator-widget>

## Sessão segura no frontend React

O scaffold não grava bearer token no `localStorage`. Login cria cookie de
sessão `HttpOnly; SameSite=Strict`; requisições de mesma origem usam
`credentials: same-origin`, e mutações autenticadas por cookie exigem
`X-CSRF-Token`. Configure `MXRB_SECURE_COOKIES=true` quando a aplicação for
servida por HTTPS. Bearer tokens estáticos continuam disponíveis para clientes
de integração que não são navegador.

## Editor e LSP

Projetos novos e exportados incluem `.ruby-version` e `ruby-lsp` no grupo de
desenvolvimento. Depois de `bundle install`, o LazyVim detecta Ruby LSP; o
frontend usa o TypeScript language server fornecido pelo projeto.

```bash
bundle install
npm ci --prefix frontend
nvim .
```

Atalhos LazyVim mais úteis: `gd` vai à definição, `gr` mostra referências,
`K` mostra documentação, `<leader>ca` abre code actions, `<leader>cr` renomeia,
`<leader>cf` formata e `<leader>xx` abre diagnósticos.
