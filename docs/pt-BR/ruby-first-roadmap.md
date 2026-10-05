# MXRB: Ruby acima de tudo

## Gráficos com dados vinculados

O frontend consulta fontes de entidades autorizadas, respeita XPath e contexto,
ordena os registros e atualiza os gráficos após alterações. Linha, área, colunas,
barras horizontais, bolhas, séries temporais, pizza e mapa de calor usam valores
reais; CustomChart aceita séries JSON explícitas de barras ou dispersão. A tabela
acessível preserva os valores, categorias comuns se alinham entre séries e valores
nulos não viram zeros. Falhas da fonte aparecem como erro, sem gráfico ilustrativo.

A fixture `marketplace_chart_project.rb`, em `spec/fixtures/frontend_browser`,
usa `MXRB_OUTPUT_PATH` e `MXRB_CHARTS_PACKAGE`. A certificação usa Charts 6.2.1:
o pacote 4.2.4 disponível localmente falhou na montagem do cliente React do
Studio 11.12.1. O pacote de terceiros não é distribuído pelo repositório.

O oráculo também revelou templates opcionais ausentes. O gerador inicializa
textos vazios nas fontes ativas, preserva fontes inativas e limpeza explícita,
e a exportação mantém os nomes das séries aninhadas. Os testes de navegador
executam a versão Ruby com abertura de MPR proibida.

O recorte nativo verifica valores e atualização de linha, barras e pizza. Não
estabelece equivalência visual completa, templates parametrizados, eventos por
ponto, temas, layouts personalizados ou todas as opções do Plotly. Agregações,
séries dinâmicas e modos de barras diferentes de `group` ainda exigem um adapter;
o renderer recusa essas configurações em vez de representar dados incorretos.
Veja a [evidência de gráficos](../evidence/chart-data-2026-10-05.json).
O CI Windows repete esse cenário com o pacote fixado por commit e checksum.

## Catálogo, regras e widgets: revisão adicional

O catálogo de aplicações `runtime_model: ruby` agora reconcilia remoções e
renomeações de declarações carregadas, preservando o manifesto de exportação.
Renomeações persistentes usam `renamed_from`; excluir uma classe não autoriza
apagar sua tabela. O modo legado continua preservando metadados não declarados.

Regras são exportadas como serviços `flow :rule`, com nível de exportação
preservado. Decisões chamam a implementação Ruby atual, inclusive após edição,
e anotações podem apontar para essas decisões. O Writer gera legendas textuais
e aceita snapshots imutáveis das declarações.

O frontend expõe `registerMarketplaceWidget` para adapters por identidade exata.
Imagens, sliders, intervalos, progresso, avaliação, cor e botões de enumeração
usam propriedades e dados vinculados, respeitando a política de edição herdada.
Scanners, ações Java/JS e outras variantes nativas continuam exigindo
implementação e certificação específicas; o recorte de gráficos está descrito acima.

VetClinic editado passou criação e leitura persistida no Chromium autenticado,
em 1280×900 e 390×900, com abertura de MPR proibida. A preparação está em
`spec/fixtures/frontend_browser/prepare_vetclinic_edited.rb`; o servidor de prova
é `serve_without_mpr.rb`, no mesmo diretório. Ambos usam uma exportação nova;
os projetos originais permanecem intactos.


A rodada adicional passou dez builds: contratos, apresentação, widgets core,
validações e compatibilidade, cada um na origem e após round-trip Ruby. Dez
casos de regras e strings passaram no Runtime de cada pacote de compatibilidade.
O oráculo revelou e permitiu corrigir a legenda não textual de decisões por regra
e a codificação URL (espaço `%20`, asterisco `%2A`, til `~`). Veja a
[evidência de compatibilidade](../evidence/compatibility-2026-10-05.json).


Busca e recorte de strings agora contam unidades UTF-16: `find` respeita a
posição inicial, `findLast` localiza a última ocorrência e `substring` rejeita
intervalos inválidos. A implementação preserva pares completos de substitutos;
strings Unicode inválidas são rejeitadas explicitamente. Os casos nativos
certificados constam na [evidência de strings](../evidence/string-parity-2026-10-05.json).


## Atualização de 5 de outubro de 2026

O catálogo do runtime descobre novos modelos, DTOs, páginas, enums e serviços
nos arquivos Ruby carregados, sem exigir edição manual do manifesto. Aplicações
com `runtime_model: ruby` executam sem abrir MPR; projetos legados precisam ser
exportados novamente para adotar esse contrato. A reconciliação automática exige o contrato Ruby; entradas legadas ainda
precisam de uma nova exportação.

A UI avalia papéis de módulo e expressões de visibilidade/editabilidade,
combinando-os com a política herdada do Data View. Papéis desconhecidos não
liberam acesso. Isso complementa a autorização do servidor. XPath inclui funções
de strings e datas, palavras de período e fuso horário da sessão; limites de
mês/ano usam calendário, com testes de DST. A cobertura não representa paridade
universal entre bancos e todas as funções nativas.

Callbacks persistentes e transitórios alcançam subtipos. Regras de validação
herdadas agora verificam obrigatoriedade, unicidade entre tabelas de subtipos,
igualdade, intervalos inclusivos e comprimento UTF-16 antes do commit com eventos.
Falhas revertem a transação e retornam feedback estruturado HTTP 422. Expressões
regulares JVM exigem um adapter `regular_expression` explícito; a sintaxe não é
reinterpretada silenciosamente como Ruby Regexp. Regras desconhecidas falham
explicitamente. Uma matriz de 21 casos concordou com o Runtime nativo: veja a
[evidência de paridade](../evidence/validation-parity-2026-10-05.json). A sintaxe
de igualdade usa `Value` no armazenamento nativo; datas sem horário foram
certificadas. No 11.12.1, um limite de data com horário aceito pelo MxBuild
falhou ao iniciar o Runtime e permanece fora dessa certificação.

VetClinic editado em Ruby passou criação pelo serviço alterado, nova coluna,
projeção de página, persistência após reabrir, rollback e exclusão com MPR
proibido ([evidência](../evidence/vetclinic-ruby-2026-10-05.json)). Isso também
cobre callbacks nativos que compartilham a transação da API.

A [certificação Windows](windows-studio-pro.md) passou seis builds nativos locais
e CRUD no runtime oficial. VetClinic passou renderização e CRUD pela API nativa.
O [relatório](../evidence/native-2026-10-05.json) separa essas provas de equivalência
visual, formulários, widgets externos, Java/JS customizado e layouts móveis ainda
sem uma matriz completa. O workflow semanal adiciona build e runtime headless.

**Português** · [English](../en-US/ruby-first-roadmap.md) · [Deutsch](../de-DE/ruby-first-roadmap.md)

## Princípio arquitetural

Ruby é a única linguagem pública do MXRB.

- O modelo Mendix é lido, criado, alterado e analisado por APIs e DSLs Ruby.
- A CLI é apenas uma camada fina sobre essas APIs.
- Não haverá MDL, parser de uma linguagem paralela ou sintaxe própria concorrendo com Ruby.
- Recursos sem abstração concisa continuam sem perdas e editáveis nos Hashes
  Ruby gerados por `native_unit`.
- Studio Pro e MxBuild são validadores externos importantes, mas não são dependências do núcleo Ruby.

## Capacidades

### Prioridade acordada em 1 de outubro de 2026

Converter projetos Mendix em aplicações Ruby + React/TypeScript editáveis e
executáveis sem runtime Mendix. A classificação de retorno ao Studio Pro não
substitui essa verificação. Preservar um artefato opaco não encerra sua conversão;
`runtime_only` pode ser código editável perfeitamente adequado ao destino Ruby.

O primeiro recorte removeu dependências do baseline para opções de campos,
aplicou editabilidade e eventos no React, corrigiu persistência de objetos de
fontes microflow, preservou foco e implementou Data Views por seleção e
associações em múltiplas etapas. Evidências e limites estão no
[contrato de conversão](portabilidade-ruby-typescript.md).

O segundo recorte implementa seleção por rádio booleana/enumeração e título da
página, torna as abas interativas com teclado e preservação de rascunhos, e
projeta valores/legendas de enumeração a partir do Ruby carregado. O terceiro
bloco adiciona implementações web e fontes editáveis para os dez tipos restantes:
`file_manager`, `image_uploader`, `image_viewer`, `menu_bar`, `navigation_list`,
`navigation_tree`, `reference_set_selector`, `scroll_container`, `snippet` e
`static_image`. Menus, snippets e imagens são exportados em `app/presentation`
e assets públicos; arquivos têm API autorizada e persistência em SQLite.
Novas exportações executam os grafos construídos das declarações Ruby e não
abrem o MPR. Chamadas internas respeitam implementações Ruby dos serviços.
O fixture de apresentação foi validado com MPR e sidecar de reconstrução
retirados da aplicação, incluindo seleção múltipla persistida após recarregar.

O quarto bloco acrescenta parâmetros nomeados de snippets, caminhos compostos
de seletores, predicados XPath simples sobre dados autorizados, tamanhos/toggles
de regiões, fontes alternativas de imagens e composição de layouts Ruby com
placeholders. Menus preservam parâmetros, tradução e módulo da ação; arquivos
têm políticas por entidade, metadados declarados e exclusão transacional pelo
runtime. O fluxo de apresentação passou inicialmente em 31 passos no Chromium sem MPR.

O quinto bloco move XPath de seletores para o servidor e compartilha o parser
com retrieves: associações diretas/inversas, predicados aninhados, contexto
autorizado e paginação após filtro. Atributos herdados passam a existir no
runtime; consultas, associações e arquivos resolvem subtipos pela entidade base,
com permissões do tipo concreto. `System.FileDocument` fornece metadados e
`System.Image` exige imagem. Thumbnails PNG são gerados por ImageMagick,
armazenados em cache no SQLite e invalidados por substituição/exclusão.
Snapshots do interpretador também preservam blobs e miniaturas no rollback.
O fixture ampliado tem 33 passos no Chromium, sem MPR nem sidecar, além de
contratos de persistência, acesso e HTTP em `ruby_runtime_compatibility_spec.rb`.

A existência desses contratos **não** certifica todas as variantes nativas:
funções/eixos/tokens restantes de XPath, todos os eventos/validações herdados,
ações cliente adicionais e layouts móveis ainda precisam de implementação e
gates próprios. Não chamar o conjunto de variantes avançadas de concluído.

Ainda devem ser fechados, com provas de edição e execução:

1. Variantes dos widgets core, ações cliente, layouts/snippets, validações e fontes de
   dados ainda sem equivalente funcional no frontend Ruby.
2. Variantes nativas adicionais de visibilidade/editabilidade; contratos de
   widgets externos e custom actions, com adapters explícitos.
3. Grafos sem declaração Ruby e integrações externas: produzir implementações
   ou adapters explícitos. O runtime novo não usa o MPR como fallback. Aplicações
   legadas sem `runtime_model: ruby` conservam o bridge antigo até nova exportação.
4. Gates em projetos reais: editar o código exportado, testar a aplicação
   convertida e distinguir qualquer dependência residual de mera preservação
   opcional para round-trip. Não declarar conversão universal com base apenas
   em cobertura de linhas ou compilação de MPR.

### Disponível

- Leitura e escrita profunda de MPR v1 e v2.
- Exportação de MPR para projeto Ruby editável.
- Geração, validação e comparação estrutural.
- Índice semântico de módulos, entidades, atributos, associações e documentos.
- Consultas Ruby de referências, chamadores, chamadas e impacto transitivo.
- Comandos CLI `refs`, `callers`, `callees` e `impact`, todos delegando à API Ruby.
- Renomeação profunda com prévia Ruby e aplicação explícita.
- Análise estática Ruby de ciclos, alvos ausentes, referências externas,
  artefatos não referenciados e acoplamento entre módulos.
- Regras de lint personalizadas escritas como objetos chamáveis Ruby.
- Diff semântico tipado em Ruby, com mudanças `added`, `removed` e `changed`.
- Navegação estrutural por busca, descrição de relações e árvore semântica.
- Avaliações executáveis de modelo em Ruby, com checks reutilizáveis, severidade,
  score e extensão por blocos Ruby.
- Testes funcionais de microflows definidos em Ruby, instrumentados numa cópia
  descartável e executados pelo runtime Mendix sem JUnit.
- Materialização incremental de páginas, microflows e nanoflows declarados nas
  classes Ruby, com IDs estáveis, papéis, widgets, chamadas e navegação.
- Round-trip de fluxos Ruby-first até TypeScript, incluindo
  página → nanoflow → microflow → retorno visível na página.
- Execução local ou Docker de `mx check`, pacote portátil e runtime, com seleção
  automática da família Java do projeto.
- Gate nativo de cobertura exigindo 100% de linhas e 100% de branches no CI e
  localmente.

Projetos graváveis mantêm um cache do índice semântico identificado por
fingerprint. `mxrb cache status`, `warm` e `clear` expõem métricas e manutenção;
a troca usa upsert antes da limpeza da entrada antiga.

A validação nativa exata do Mendix 5 continua dependente de Windows/Studio Pro.
Ela fica documentada como limitação legada remota e não é um gate atual de
entrega.

### Reconciliação do ciclo de vida Docker

Os comandos `mxrb db up` e `mxrb db sync` convergem para um único workspace por
projeto, sem criar uma segunda pilha a cada execução. O contrato entregue é:

1. calcular um fingerprint do MPR, fontes, Dockerfile/Compose, imagem e opções
   relevantes, sem incluir nem registrar o conteúdo de segredos;
2. reutilizar containers e recursos existentes quando o fingerprint não mudou;
3. quando o projeto mudou e os recursos estão parados, compilar em staging e
   recriar somente recursos obsoletos que tenham labels de propriedade do MXRB;
4. quando uma versão anterior ainda está rodando, não substituí-la
   silenciosamente. A CLI deve avisar qual fingerprint está ativo e perguntar se
   o usuário deseja encerrá-la e recriar. Recusar mantém a versão anterior e não
   inicia uma segunda pilha;
5. em execução não interativa, nunca aguardar stdin: exigir uma opção explícita,
   como `--recreate` ou `--keep-current`, e falhar com instrução clara quando ela
   estiver ausente;
6. remover automaticamente apenas volumes efêmeros. Volumes de dados persistentes
   continuam preservados até uma confirmação destrutiva explícita;
7. nunca executar `docker system prune`. A coleta alcança somente recursos com
   labels MXRB do projeto, não referenciados pelo estado reconciliado;
8. serializar `up`, rebuild e cleanup com um lock por projeto; falha de build não
   toca a versão ativa e falha ao iniciar a substituta restaura o pacote e o
   container anteriores.

Em terminal interativo a CLI pergunta antes de substituir uma versão ativa. Em
CI ou stdin não interativo, ela falha com instrução para escolher
`--recreate` ou `--keep-current`. A coleta seletiva cobre containers e redes
obsoletos, imagens MXRB dangling e volumes marcados `mxrb.ephemeral=true`;
volumes persistentes continuam fora da coleta automática.

Perfis de navegação agora leem e escrevem documentos nativos Mendix, incluindo
homes por papel e menus recursivos. Assets de tema e código fazem round-trip
com manifesto de checksums; tokens possuem inventário, lint, métricas de
contraste e migração de literais com preview.

## API semântica

```ruby
Mxrb.open("app.mpr") do |project|
  order = project.find_artifact("Sales.Order")
  refs = project.references_to(order)
  callers = project.callers_of("Sales.Recalculate")
  callees = project.callees_of("Sales.Checkout")
  impact = project.impact_of("Sales.Order")

  impact.artifacts.each do |artifact|
    puts "#{artifact.kind}: #{artifact.qualified_name}"
  end
end
```

Os resultados são objetos Ruby imutáveis: `Mxrb::Semantic::Artifact`,
`Mxrb::Semantic::Reference` e `Mxrb::Semantic::Impact`.

Projetos abertos para escrita persistem no MPR um cache do índice semântico com
fingerprint. Aberturas somente leitura podem reutilizá-lo, mas nunca alteram o
projeto.

Uma renomeação é sempre inspecionável antes da escrita:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Order", to: "Invoice")
  plan.changes.each { |change| puts change.inspect }
  plan.apply!
end
```

Na CLI, `mxrb rename app.mpr Sales.Order Invoice` apenas mostra a prévia.
Acrescente `--apply` para efetivar a alteração.

## Remoção segura

Units independentes, como microflows e páginas, podem ser inspecionadas antes
da remoção:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plano = project.plan_remove("Sales.FluxoSemUso")
  plano.apply! if plano.safe?
end
```

O plano é bloqueado enquanto houver referências recebidas ou units filhas.
Elementos embutidos no domínio exigem sua mutação tipada. Na CLI,
`mxrb remove app.mpr Sales.FluxoSemUso` mostra a prévia e `--apply` só grava
um plano seguro.

## Movimentação segura no módulo

Units independentes podem ser movidas para um módulo ou pasta sem alterar seu
nome qualificado nem suas referências:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plano = project.plan_move("Sales.Processar", to: "Sales.Automacao")
  plano.apply!
end
```

O plano preserva o tipo nativo de contenção e bloqueia elementos embutidos do
domínio, destinos que não são containers, ciclos de pastas e movimentos entre
módulos. `mxrb move app.mpr Sales.Processar Sales.Automacao` mostra os IDs dos
containers; `--apply` executa a transação.

## Análise estática

```ruby
report = Mxrb.open("app.mpr", &:analyze)

report.errors.each { warn _1.message }
report.unreferenced.each { puts _1.qualified_name }
report.call_cycles.each { puts _1.artifacts.map(&:qualified_name) }
report.module_dependencies.each { puts "#{_1.from} -> #{_1.to}" }
```

Integrações externas desconhecidas geram aviso; um alvo ausente dentro de um
módulo existente gera erro. Referências `System.*` são reconhecidas como parte
da plataforma Mendix.

## Diff semântico

```ruby
result = Mxrb.diff("before.mpr", "after.mpr")

result.added.each { puts _1.path }
result.removed.each { puts _1.path }
result.changed.each { puts "#{_1.before} -> #{_1.after}" }
```

`mxrb diff before.mpr after.mpr` imprime uma mudança tipada por linha, adequada
para logs e revisão em Git. `mxrb compare` continua compatível com a saída
textual anterior.

## Navegação

```ruby
project.search_artifacts("checkout", kind: :microflow)
project.describe_artifact("Sales.Checkout")
```

Os comandos equivalentes são `mxrb find`, `mxrb describe` e `mxrb tree`.

## Avaliações de modelo

```ruby
result = Mxrb.open("app.mpr") do |project|
  project.evaluate do
    artifact "Sales.Order", kind: :entity
    no_call_cycles
    no_missing_internal_references
    maximum_unreferenced 20, severity: :warning
    forbid_dependency from: :Domain, to: :Presentation
  end
end

abort result.errors.map(&:message).join("\n") unless result.passed?
```

Arquivos de avaliação são Ruby comum e rodam com
`mxrb evaluate app.mpr evaluation.rb`; não existe linguagem de regras paralela.

## Marketplace oficial Mendix

Esta família permanece separada de `mxrb module`, que instala módulos Ruby do
catálogo interno. O formato entregue é:

```sh
mxrb marketplace search "Community Commons"
mxrb marketplace show 170
mxrb marketplace versions 170 --mendix-version 11.12.1
mxrb marketplace pull 170 --mpr App.mpr
mxrb marketplace update 170 --mpr App.mpr
mxrb marketplace update 170 --mpr App.mpr --apply
mxrb marketplace remove CommunityCommons --mpr App.mpr
mxrb marketplace remove CommunityCommons --mpr App.mpr --apply
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr App.mpr
mxrb marketplace login --pat-file .env
mxrb marketplace audit
```

Capacidades entregues:

1. API oficial: pesquisar conteúdo público/privado, resolver versões compatíveis,
   baixar pelo `downloadURL` e auditar vulnerabilidades e atualizações.
2. GitHub: resolver releases públicas, baixar `.mpk` ou arquivo da release,
   extrair com proteção contra caminhos inseguros e registrar versão, origem e
   checksum em lockfile.
3. MPK local: ler o MPR interno e importar diretamente todas as units e assets
   no MPR de destino via Ruby/SQLite/BSON, sem ferramentas Mendix.
4. PAT Mendix: validar e armazenar com permissões restritas, exigindo o escopo
   `mx:marketplace-content:read` e enviando-o somente ao host oficial da API.
5. Lifecycle transacional: `update` e `remove` são prévias por padrão, preservam
   IDs referenciados externamente, recusam assets alterados e protegem MPR,
   `mprcontents`, cache, lock e assets antes de `--apply` explícito.
6. Dependências oficiais: `marketplace dependencies` lê referências no MPR
   interno, resolve recursivamente, confirma a identidade real em cada MPK,
   reconhece módulos do próprio projeto, instala folhas primeiro e faz rollback.
7. Export/rebuild autenticado: os grafos Kafka passaram em 10.24 e 11.12, com
   assets, checksums e diagnósticos fonte/reconstrução preservados.
8. Frontend oficial: DataWidgets 3.11.3 foi importado com Content ID 116540 e
   Version ID `e7b6d703-8e47-42f4-bb92-934e3601e71b`; o Combo box é o componente
   oficial independente Widget/clientModule 219304, versão 2.9.0, Version ID
   `dce845f4-d051-4161-847c-016c01703caa`. A instalação faz backup e substitui
   o asset 2.6.x antes pertencente ao Atlas Core (Content ID 117187).
9. Aceitação reproduzível: `script/frontend_acceptance` bloqueia drift de
   modelo, assets, checksums ou proveniência do lock/cache/originais. O renderer
   nativo tem zero achados de preflight na origem e reconstrução das fixtures
   aceitas de 10.24 e 11.12.
10. Migração segura: `mxrb frontend migrate App.mpr` mostra a prévia e somente
    `--apply` grava um plano transacional considerado seguro.

GitHub não cobre módulos sem fonte ou release pública; MPK local continua útil
como rota offline. A integração oficial usa somente o contrato OpenAPI publicado.
A trilha de migração está concluída em toda a matriz de frontend suportada. O
oráculo MxBuild externo e opcional retorna zero erros na origem e reconstrução
de 10.24 e 11.12; `mx check` também preserva diagnósticos observáveis dos
pacotes byte a byte em cada round-trip. O MXRB permanece independente: `mx` e
MxBuild são somente oráculos de validação, nunca geradores, mutadores ou
dependências de runtime.

### Continuação de 02/10: ações cliente e grid responsivo

Salvar/Cancelar mantém rascunhos por página, com confirmação atômica e ACL por
objeto/membro no backend; Excluir/Fechar deixa de ser tratado como microflow.
A opção ClosePage retorna ao MPR, efeitos de fechamento são aplicados e o
histórico restaura página/contexto. LayoutGrid aplica os pesos e alinhamentos
por desktop/tablet/celular. O fixture existente cobre 54 passos de navegador,
com mais dois cenários de viewport. Ver o recorte e as limitações específicas
em `portabilidade-ruby-typescript.md`: uploads/efeitos de flows fora do lote,
modais, outras ações nativas, parâmetros avançados e equivalência visual ampla
continuam fora desta certificação.
