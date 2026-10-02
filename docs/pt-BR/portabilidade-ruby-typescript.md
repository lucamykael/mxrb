# Portabilidade real entre Ruby, TypeScript e Mendix

## Direção principal: Mendix → Ruby + React/TypeScript

O objetivo da conversão é uma aplicação com backend e regras em Ruby e frontend
web editável em React/TypeScript, sem executar o runtime Mendix. Retornar ao MPR
é um contrato adicional, não o critério de autonomia da aplicação Ruby.
`runtime_only` não significa fonte opaco: código Ruby e rotas React próprios
podem ser integralmente editáveis mesmo sem projeção de volta ao Studio Pro.
Por isso, `portability --require-native` verifica a direção Ruby → Mendix;
ele **não** certifica a conclusão de Mendix → Ruby.

Novas exportações declaram `runtime_model: ruby`: o modelo de execução, esquema
de persistência, segurança e grafos vêm das definições Ruby carregadas. Não se
abre nem se gera um MPR para executá-los. O manifesto e metadados de identidade
continuam presentes; não são interpretados como código de negócio. MPR e
sidecar de reconstrução são preservados para round-trip, não como fallback de
execução. Aplicações antigas sem essa configuração mantêm o bridge legado;
faça nova exportação para obter o contrato novo.

Schemas de widgets pluggable são exportados separadamente em
`.mxrb/widget_schemas`, mantendo a revisão exata de cada widget por página,
layout ou snippet. Eles validam as propriedades Ruby sem abrir o MPR; não
contêm os valores de negócio dos widgets. Uma exportação nova exige esses
schemas e falha explicitamente se estiverem ausentes.

Widgets incomuns de layouts podem aparecer como `form_widget(Mxrb::Forms...)`:
suas propriedades continuam editáveis em construtores tipados, sem hashes ou
referências a fragmentos opacos. Essa representação não acrescenta um renderer
web para tipos ainda não suportados.

Isso não traduz automaticamente grafos sem declaração Ruby nem implementações
Java externas: exigem implementação Ruby/adapter explícito. Preservação desses
artefatos não conta como funcionalidade concluída.

### Dez widgets de apresentação e execução sem MPR

`menu_bar` e `navigation_tree` usam menus recursivos de `app/presentation`, com
ações de página/microflow/nanoflow, parâmetros, traduções de legenda, ícones e
filtragem pelas permissões. Referências mantêm o módulo de origem do menu;
ações negadas são removidas mesmo quando seus filhos continuam autorizados. `navigation_list`
preserva conteúdo e ações de seus itens. `snippet` expande widgets reutilizáveis
com parâmetros nomeados de objetos/escalares, mapeamentos e proteção contra
recursão. DataViews podem editar objetos diferentes no mesmo snippet sem trocar
o objeto da página. Parâmetros ausentes são reportados.
`static_image` aponta para arquivos exportados em `frontend/public/assets/images`.
`scroll_container` preserva as cinco regiões, dimensões em pixels/percentual,
layouts headline/sidebar e os modos de abertura/fechamento, sobreposição e
deslocamento. Layouts compartilhados também são declarações Ruby em
`app/presentation`: seus placeholders recebem argumentos nomeados e layouts
aninhados são compostos a cada leitura da página, com detecção de ciclos.

`reference_set_selector`, incluindo a forma nativa InputReferenceSetSelector,
grava coleções de referências e respeita bloqueios herdados. Referências aos
objetos-alvo e leitura das associações são autorizadas no backend. Caminhos
compostos resolvem um único objeto proprietário antes de gravar; caminhos
ambíguos/vazios não viram consultas sem escopo. O servidor avalia XPath antes da
paginação: comparações, booleanos, aritmética, funções de strings, referências
a variáveis, caminhos de associações diretas/inversas e predicados aninhados.
Por exemplo, `[App.Item_Tags/App.Tag[Name = 'Visible']]` filtra pelo objeto
relacionado. Caminhos vazios não correspondem a objetos e comparações de conjuntos
são existenciais. O mesmo avaliador atende retrieves de microflows.
Cada objeto e membro acessado pela consulta HTTP passa por autorização; campos
privados não podem ser usados para inferir resultados. O contexto de
`$currentObject` é recuperado do banco e autorizado. Referências previamente
selecionadas fora do filtro são preservadas. Sintaxe inválida é rejeitada, com
limites de tamanho e profundidade. Isso não implementa todos os eixos, tokens e
funções do XPath nativo.

`file_manager`, `image_uploader` e `image_viewer` usam `/api/files/:entity/:id`.
O backend exige autorização sobre o objeto e seu membro `Contents`; mutações
por cookie também exigem CSRF. Conteúdo binário fica no banco SQLite, com teto
de 20 MiB por arquivo. Nome e MIME fornecidos pelo cliente não controlam caminhos
de disco nem conteúdo executável: somente assinaturas raster reconhecidas são
exibidas inline; os demais arquivos são anexos, com `nosniff` e CSP restritiva.
Limites/extensões próprios do widget são verificações adicionais da UI, não uma
política de segurança do servidor. O modelo Ruby pode declarar
`file_policy max_bytes: 1048576, extensions: %w[png], images_only: true`, aplicada
também contra uploads que ignoram a UI. `Name`, `FileSize` e `HasContents` são
atualizados também quando herdados de `System.FileDocument`. `generalizes`
resolve atributos da cadeia de entidades nas tabelas, nos objetos Ruby e no
schema enviado ao frontend. Consultas pela entidade base encontram seus subtipos,
inclusive associações com destino em `System.FileDocument` ou `System.Image`.
Uploads para subtipos de `System.Image` exigem assinatura raster. CRUD e arquivos
verificam as permissões do tipo concreto: consultar pela base não concede acesso
adicional. As regras de acesso continuam próprias de cada entidade, conforme o
[contrato de segurança do Mendix](https://docs.mendix.com/refguide/access-rules/).
Um trigger transacional remove blobs na exclusão pelo runtime, inclusive com
eventos desativados; rollback SQL e restauração de snapshots do interpretador
restauram registro, conteúdo e miniaturas. Downloads usam cookie de mesma origem.
Imagens usam fontes de contexto, associação, microflow e nanoflow; dimensões
percentuais/automáticas, fallback e abertura da imagem são cobertos.

`show_as_thumbnail` solicita uma miniatura PNG real pelo mesmo endpoint, com
`thumbnail_width` e `thumbnail_height` entre 1 e 1024. A imagem mantém proporção,
não é ampliada e tem orientação corrigida e metadados removidos. GIF/WebP animado
usa o primeiro quadro. O cache no SQLite é invalidado por substituição/exclusão
do arquivo e respeita as mesmas permissões do download original.
O processamento requer ImageMagick 7 (`magick` no PATH), ou ImageMagick 6 com
`MXRB_IMAGEMAGICK=convert`. A ausência do worker ou imagem inválida gera erro
explícito. A execução usa argumentos separados, decodificador raster explícito,
limites de memória/tempo e encerramento após 15 segundos, seguindo as opções de
[recursos do ImageMagick](https://imagemagick.org/security-policy/). A CI instala
e executa esse worker; downloads originais não precisam dele.

O fixture `spec/fixtures/ruby_presentation_widgets/project.rb` testa os dez tipos,
recursos exportados, edição pública e persistência. O cenário
`spec/fixtures/frontend_browser/ruby_presentation_widgets_flow.json` verifica
33 passos no Chromium, inclusive seleção filtrada por associação aninhada,
persistência após recarregar, solicitação de thumbnail, navegação e abertura
de região lateral com largura de 240 px,
com MPR e sidecar removidos da aplicação de teste. Upload é coberto por testes de
componente e API. `ruby_standalone_runtime_spec.rb` proíbe abrir projetos MPR e
verifica alteração de fluxos, chamada interna a Ruby personalizado e reabertura
do banco; custom actions têm teste próprio de resolução sem MPR.

Os contratos de XPath por associação, persistência polimórfica de arquivos e
miniaturas reais têm gates em `spec/runtime/xpath_spec.rb` e
`spec/ruby_runtime_compatibility_spec.rb`, incluindo reinício, permissões,
cache, rollback, HTTP e runtime proibido de abrir MPR.
O Sudoku usado na CI também inicializa 9 módulos, 19 páginas e 4 entidades
persistentes sem MPR. Senhas de demonstração ocultadas na exportação não são
necessárias para construir o modelo de autorização; credenciais do runtime
continuam sendo configuradas no `SessionManager` pelo ambiente da aplicação.

Limites ainda abertos: funções/eixos/tokens restantes do XPath completo,
equivalência de todos os eventos/validações herdados do runtime Mendix,
ações cliente nativas adicionais, parâmetros tipados/variáveis locais mais
avançadas e integrações particulares. Layouts móveis/nativos, comportamento
responsivo exato de cada tema e equivalência visual com Studio Pro não estão
certificados. Os limites novos têm testes em `ruby_advanced_presentation_spec.rb`
e nos componentes React; isso não elimina os gates pendentes em projetos reais.
Esse gate certifica o fixture e os contratos descritos, não conversão universal.

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

### Seleção por rádio, títulos e abas

`radio_button_group` oferece seleção booleana ou por enumeração, legendas,
orientação horizontal/vertical, navegação nativa por teclado, persistência e
eventos de foco/saída do grupo. Respeita os bloqueios herdados de Data Views;
opções desconhecidas são sinalizadas, sem substituir o valor armazenado.
Valores de enumeração curtos e qualificados são reconhecidos. A gravação
preserva a representação recebida, e comparações com literais de enumeração
em condições reconhecem ambas sem confundir tipos qualificados diferentes.

O schema servido usa os valores e traduções Ruby das enumerações exportadas,
com fallback ao manifesto para definições legadas sem implementação carregada.
Alterar `app/enumerations/**/*.rb` não exige recompilar o MPR; recarregue a
aplicação para obter o schema atualizado. Descoberta de novos documentos e
remoção do manifesto como catálogo ainda não estão concluídas.

`page_title` usa o título da página Ruby carregada. `tab_control` seleciona um
painel por vez, suporta setas/Home/End e mantém os campos dos painéis já abertos
montados, preservando rascunhos. Painéis ainda não abertos são carregados sob
demanda. O fixture `spec/fixtures/ruby_frontend_core_widgets/project.rb` e o
cenário `spec/fixtures/frontend_browser/ruby_core_widgets_flow.json` verificam
esse comportamento, condições por enumeração e persistência após recarregar.
Variantes nativas de abas ainda não projetadas não estão cobertas por esse contrato.

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
