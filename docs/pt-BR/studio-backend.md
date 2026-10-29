# Protocolo do backend do Studio

**Português** · [English](../en-US/studio-backend.md) · [Deutsch](../de-DE/studio-backend.md)

`mxrb studio serve` executa o MXRB como backend de uma IDE: um processo de
longa duração que fala JSON-RPC 2.0 por stdin e stdout. Cada função da IDE que
pertence ao MXRB (catálogo de comandos e tarefas, arquivos do projeto Ruby,
conversão, propriedades de documentos, operações tipadas no modelo com
desfazer e refazer, sincronização Ruby/Mendix, coordenação de escritas, ER e
consultas ao banco) é um método de `Mxrb::Studio::Service`. A IDE desenha; o
MXRB decide e persiste.

```sh
mxrb studio serve [--state-root DIR]
```

O estado (vínculos de projetos Ruby, bases de sincronização, históricos de
desfazer) fica em `$XDG_STATE_HOME/mxrb/studio`, a menos que `--state-root`
seja informado.

## Enquadramento e sessão

- Uma mensagem JSON-RPC por linha (NDJSON). Texto JSON nunca contém uma quebra
  de linha literal, então cada linha é sempre uma mensagem inteira.
- As requisições rodam em paralelo; as respostas podem chegar em qualquer
  ordem.
- A primeira requisição é `initialize`. O cliente informa as versões de
  protocolo que fala e, opcionalmente, as raízes do workspace (usadas para
  anexar arquivo e linha aos erros):

```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocol_versions":[2],"roots":["/work/shop-ruby"]}}
```

A resposta informa o protocolo (`mxrb-studio` 2), a versão do servidor, todos
os métodos, as notificações e as capacidades (cancelamento, progresso,
isolamento por fork, desfazer, sincronização, locks). Um cliente sem versão
compatível recebe o erro `-32015` com `data.supported`.

- `shutdown` espera as requisições em andamento e depois recusa novas; a
  notificação `exit` encerra o processo. Fechar o stdin cancela o que ainda
  estiver rodando.

## Métodos

| Grupo | Métodos |
|---|---|
| Catálogo e tarefas | `catalog/list`, `catalog/arguments`, `tasks/prepare`, `tasks/run`, `tasks/input`, `tasks/configurations`, `tasks/saveConfiguration`, `tasks/deleteConfiguration` |
| Arquivos | `files/list`, `files/read`, `files/write`, `files/create`, `files/move`, `files/delete`, `files/worktrees`, `files/worktreeAdd`, `files/worktreeRemove` |
| Ruby | `ruby/syntax`, `ruby/declarations` |
| Projeto | `snapshot/create`, `project/status`, `project/convert`, `project/attach` |
| Documentos | `documents/list`, `documents/read`, `documents/patch`, `documents/ruby` |
| Modelo | `model/capabilities`, `model/revision`, `model/preview`, `model/apply`, `model/history`, `model/undo`, `model/redo`, `model/catalog`, `model/domainDiagram` |
| Dados | `data/logical`, `data/connections`, `data/physical`, `data/query`, `data/explain` |
| Paridade | `parity/matrix` |
| Sincronização | `sync/link`, `sync/unlink`, `sync/status`, `sync/document`, `sync/run`, `sync/preview` |
| Locks | `locks/acquire`, `locks/release`, `locks/status` |

`catalog/list` devolve todos os comandos públicos da CLI e os scaffolds com um
esquema tipado de argumentos; `tasks/run` executa um deles como processo filho
e transmite as notificações `tasks/started` e `tasks/output`. Cancelar a
requisição interrompe a tarefa (`cancelled: true` no resultado).

`ruby/syntax` analisa com o Prism e devolve diagnósticos com linha e coluna;
`ruby/declarations` lista os artefatos Mendix que um arquivo declara
(`entity`, `page`, `microflow`, ...) com os nomes qualificados. Nenhum dos dois
avalia Ruby.

`documents/ruby` recebe `source_model` e `unit_id` (UUID da unidade nativa), além
de `qualified_name` e `type` BSON opcionais para confirmar a identidade. Retorna
`state: "ready"`, `root`, `path` relativo e `line` quando encontra uma declaração
Ruby inequívoca do documento. O vínculo do projeto é resolvido pelo backend;
o cliente não escolhe outra raiz para essa operação. A busca usa o tipo, módulo
e nome da unidade nativa, declarações Prism e metadados de identidade dos flows,
sem executar Ruby nem depender do nome do arquivo. Arquivos movidos dentro do
módulo continuam localizáveis; symlinks e fontes fora da raiz não são seguidos.

Sem um projeto Ruby vinculado, um documento suportado retorna
`state: "missing_project"`: o host pode perguntar se o usuário quer converter,
salvar/criar seu snapshot, chamar `project/convert` e repetir a consulta antes
de abrir o editor central. `state: "unavailable"` inclui `reason` e `message`
para documento desconhecido, tipo não suportado, identidade divergente,
declaração ausente ou ambígua. A operação não reconverte nem sobrescreve um
projeto Ruby existente.

A busca cobre todas as famílias de documentos emitidas pelo exportador: flows,
pages, layouts/snippets/templates, menus, enumerações/constantes, integrações,
mappings, actions, workflows, jobs, assets e os documentos globais de settings,
textos, segurança e navegação. Declarações genéricas `native_document` e
`native_unit` usam o UUID exato, incluindo extensões preservadas pelo MXRB.
Project e Module apontam para suas declarações no projeto vinculado.

Agregados como DomainModel retornam `state: "choose"`, `root` e
`files: [{path, line, label}]` quando existem vários arquivos correspondentes.
O host apresenta essa lista antes de abrir o editor. O domínio inclui seu
índice verificado pelo loader e declarações de entidades, DTOs e views OQL;
associações ficam no arquivo da entidade de origem. Cada `label` de entidade
usa o nome qualificado, como `Sudoku.Cell`. Um único arquivo retorna `ready`.
Duplicações conflitantes da mesma declaração continuam `ambiguous_source`,
sem selecionar um arquivo arbitrário. Unidades de infraestrutura preservadas
somente no baseline JSON (Folder, ModuleGuidMapping, ModuleSettings e
ProjectConversion) não inventam uma representação Ruby.

`files/write` e `documents/patch` recebem a revisão que o cliente leu por
último e falham com conflito quando o arquivo ou a unit mudou nesse meio
tempo, de modo que as duas versões são preservadas.

## Operações dos painéis

`tasks/configurations`, `tasks/saveConfiguration` e `tasks/deleteConfiguration`
guardam configurações de tarefas nomeadas por caminho de `project` na raiz de
estado. Uma configuração salva guarda um comando do catálogo, os valores dos
campos e argumentos extras; marcadores como `{mpr}` não são resolvidos. Comandos,
campos ou escolhas desconhecidos são rejeitados ao salvar, e os nomes são únicos
por projeto.

`files/delete` remove um arquivo, ou uma pasta com `recursive: true`; uma
`revision` opcional ainda precisa coincidir. Metadados Git e a raiz do workspace
não podem ser removidos. `files/worktreeAdd` adiciona uma worktree Git em um
caminho absoluto fora da worktree atual, em um branch novo ou existente;
`files/worktreeRemove` nunca força a remoção, então uma worktree com alterações
locais é mantida. `project/attach` vincula o projeto nativo a outra worktree do
mesmo projeto Ruby.

`data/connections` lista as conexões de banco de um modelo com ambiente, host,
porta, banco, usuário e estado. `data/physical`, `data/query` e `data/explain`
exigem `connection: {id}` explícito e repetem a conexão em cada resultado; uma
escolha ausente ou obsoleta falha com `connection_required` (-32020). Tabelas
físicas e chaves estrangeiras vêm apenas do catálogo do PostgreSQL; o modelo
lógico nunca as confirma. Resultados de consulta e de plano incluem o SQL
executado, tornando visíveis as traduções de OQL.

`parity/matrix` devolve a matriz de paridade nos dois sentidos: capacidades do
Studio Pro com as APIs/DSL Ruby do MXRB, de um inventário revisado, e operações
do MXRB com a superfície da IDE que as alcança, derivadas do catálogo de comandos
e deste protocolo. Cada capacidade tem estados por dimensão; nada é agregado em
um número de conclusão.

## Progresso, cancelamento e erros

- `$/cancelRequest` com `{"id": ...}` cancela uma requisição.
- Operações longas enviam notificações `$/progress` (`token` = id da
  requisição, `kind` = `begin`/`report`/`end`, `current`, `total`, `detail`).
  Toda operação do MXRB que mostra progresso no terminal o reporta aqui, e cada
  atualização é um ponto de cancelamento.
- Avaliar um projeto Ruby e exportar um modelo rodam num processo filho
  (fork): uma definição que chama `exit`, entra em laço ou esgota a memória não
  derruba o servidor, e cancelar encerra o processo filho.

Os erros são objetos de erro JSON-RPC com `data.kind` e, quando conhecidas,
`data.locations` (`file`, `line`, `column`):

| Código | `kind` | Significado |
|---|---|---|
| -32700 / -32600 / -32601 / -32602 | `parse_error` / `invalid_request` / `method_not_found` / `invalid_params` | condições do JSON-RPC |
| -32002 | `not_initialized` | requisição antes de `initialize` |
| -32800 | `cancelled` | a requisição foi cancelada |
| -32010 | `conflict` | o alvo mudou desde a leitura; nada foi sobrescrito |
| -32011 | `busy` | outro processo está gravando o modelo; tente de novo |
| -32012 | `validation` | o modelo ou a operação é inválido |
| -32013 | `toolchain` | uma ferramenta ou chamada de sistema necessária falhou |
| -32014 | `ruby_source` | o Ruby não compila ou não avalia; veja `locations` |
| -32015 | `unsupported_protocol` | nenhuma versão de protocolo em comum |
| -32603 | `internal_error` | qualquer outro caso |

## Escritas coordenadas

Todo escritor MXRB de um modelo ou workspace obtém um `flock` exclusivo em
`$XDG_STATE_HOME/mxrb/studio/locks/<sha256 do caminho canônico>`. Uma IDE que
grava o mesmo modelo obtém o mesmo lock, diretamente ou por `locks/acquire`
(o servidor mantém o lock para o lease até `locks/release` ou o fim da
conexão). `locks/status` informa se alguém o detém. O MXRB espera até 30
segundos e então responde `busy`.

## Desfazer e refazer

`model/apply`, `documents/patch` e `sync/run` registram uma entrada no
histórico com os bytes nativos exatos de cada unit adicionada, removida ou
alterada. `model/undo` os restaura byte a byte (IDs, referências e layout
incluídos); `model/redo` os reaplica. Uma entrada só é desfeita enquanto suas
units ainda têm o estado que ela deixou; caso contrário a requisição falha com
conflito e nada é gravado. O histórico guarda as últimas 100 entradas.

## Sincronização Ruby e Mendix

`sync/preview` recebe `source_model` e, opcionalmente,
`expected_revisions: {"model": "<sha256>", "ruby": "<sha256>"}`. Resolve a
representação Ruby pelo vínculo do projeto; não aceita outra raiz fornecida
pelo cliente. Cria um snapshot nativo e uma cópia temporária dos arquivos
Ruby, compila apenas essa cópia e devolve a comparação
`comparison: "saved_model_to_generated_ruby"`, sempre com `applied: false`.
Não chama `sync/link`, não atualiza `.mxrb/` original e não substitui o vínculo
Ruby. Os temporários são removidos ao terminar, falhar ou cancelar.

A resposta inclui `root`, `revisions`, `current_revisions`, `units` e
`validation: {errors, warnings}`. Cada unit indica `unit_id`, `type`, `name`,
`action` (`added`, `removed`, `modified`) e alterações por elemento em
`changes`: operação, elemento, propriedade e valores antes/depois. As flags
`before_present`/`after_present` distinguem ausência de uma propriedade de um
valor nulo. Payloads binários aparecem pelo tamanho e SHA-256.
`state: "ready"` significa que a comparação terminou; não afirma que o
resultado pode ser aplicado. `stale` indica revisão divergente antes ou depois
da execução; `missing_project` indica ausência de representação Ruby válida.
Uma troca de vínculo durante a compilação também retorna `stale`, com
`reason: "linked_project_changed"` e `current_root`, preservando o novo vínculo.

Essa prévia não carrega uma base histórica de sincronização:
`conflicts: {assessed: false, reason: "no_sync_baseline"}`. Ela inclui apenas
arquivos salvos e o resultado efetivo da compilação. Defaults normalizados
pelo compilador podem aparecer mesmo sem edições Ruby. A reconciliação de IDs
por nome/posição serve para apresentar diferenças, não garante um futuro
apply. Remover uma declaração Ruby pode manter o documento preservado pelo
baseline nativo. Esses limites também estão em `limitations`; não existe
operação de aplicação associada a essa resposta.

A execução exige Linux com Bubblewrap funcional: sistema/runtime, gems e
biblioteca MXRB são somente leitura; apenas a cópia privada fica gravável.
O worker usa namespaces próprios de processos e rede, HOME temporário e
ambiente reduzido, sem montar as pastas pessoais de credenciais. O snapshot
usado como comparação permanece fora do workspace gravável do worker.
Se o isolamento não iniciar, retorna `unavailable/isolation_unavailable`, sem
executar uma alternativa irrestrita. Symlinks de fontes são recusados. Os
limites iniciais são 25 mil arquivos/512 MiB de fontes, 120 segundos de
compilação e 128 KiB de stdout/stderr; erros Ruby trazem arquivo e linha.

`sync/link` registra a base sincronizada de um modelo e do seu projeto Ruby:
uma cópia do modelo, uma cópia dos arquivos Ruby, a exportação Ruby do modelo
e o modelo gerado a partir do Ruby. `sync/status` é barato: arquivos Ruby
alterados com diagnósticos e artefatos declarados, units Mendix alteradas e
conflitos não resolvidos, resumidos como `synced`, `pending`,
`conversion_error` ou `conflict`.

`sync/run` sincroniza as duas direções:

1. **Edições Mendix** são as units cujo significado difere do modelo base.
   Ordem de propriedades, IDs recém-gerados e a ordem das entidades não contam
   como mudança.
2. **Edições Ruby** são as units cuja geração a partir do Ruby atual difere da
   geração do Ruby base. Elas são expressas como operações por elemento
   (alterar uma propriedade, inserir, remover ou reordenar um filho) nos IDs do
   modelo, de modo que aplicá-las preserva IDs, referências, layout e toda
   propriedade não tocada. Apagar a declaração Ruby de um documento remove o
   documento.
3. Um elemento alterado pelos dois lados é um **conflito**. Uma execução com
   conflitos não grava nada e devolve cada conflito com os valores da base, do
   Mendix e do Ruby (`kind` `element`, `unit` ou `file`). Executar de novo com
   `resolutions` (`{"<id do conflito>": "ruby" | "mendix"}`) aplica tudo.
4. As edições Ruby são aplicadas ao modelo numa única transação registrada no
   histórico, sob o lock de escrita, apenas se o modelo não mudou durante a
   execução.
5. As edições Mendix são mescladas nos arquivos Ruby com um merge de três vias
   por linha: comentários e código Ruby fora das linhas alteradas ficam como
   estão. Uma alteração de um lado ao lado de uma inserção do outro não é
   conflito. Arquivos sobrescritos são copiados antes para a pasta de backup da
   base.
6. `.mxrb/` (a linha de base nativa e o manifesto de assets) pertence ao MXRB e
   sempre espelha o modelo sincronizado.

Ruby que não compila ou não avalia deixa o modelo intocado; a execução falha
com `ruby_source` e as localizações do erro. O último modelo válido continua
como está e as alterações Ruby continuam pendentes.

`sync/status` também informa as units `diverged`: units em que o modelo gerado
a partir do Ruby sincronizado significa algo diferente do próprio modelo. Elas
mostram que partes do modelo a projeção Ruby ainda não captura; o conteúdo
nativo delas é preservado, não convertido.

Medido no exemplo público Sudoku (409 units, 355 arquivos Ruby, Ruby 4.0, um
núcleo por processo): vincular 23 s, Ruby para Mendix 21 s (dominado pela
geração do projeto inteiro a partir do Ruby), Mendix para Ruby 5 s,
`sync/status` 0,2 s.

### Coordenação com uma IDE aberta

- **Revisões.** `sync/status` e `sync/run` respondem `revisions: {model, ruby}`
  (SHA-256 das units e dos arquivos Ruby). Enviadas de volta como
  `expected_revisions`, a execução recusa (`conflict`) aplicar algo diferente
  do estado comparado.
- **Cópia do Ruby.** A geração usa uma cópia privada dos arquivos Ruby feita no
  início. Ruby salvo durante a execução continua pendente e nunca entra na nova
  base. Antes de gravar, sob o lock do modelo e depois o do projeto Ruby, cada
  arquivo reescrito pela mescla precisa manter o texto copiado; senão nada é
  gravado (`conflict`). Os arquivos mesclados são substituídos atomicamente.
- **Leases.** Uma IDE que segura as próprias gravações até recarregar o modelo
  usa `locks/acquire` e passa o `lease` para `sync/run`.
- **Sandbox.** A geração roda no mesmo Bubblewrap de `sync/preview`; sem
  isolamento a execução falha (`toolchain`/`isolation_unavailable`). Só quem
  inicia o servidor pode relaxar com `MXRB_STUDIO_SYNC_ISOLATION=process`.
- **Conflitos** encontrados (inclusive em dry run) ficam guardados com as
  revisões; `sync/status` deixa de mostrá-los quando qualquer lado muda.
- **Artefatos.** `sync/status` lista `documents` (por unit nativa: o que Ruby e
  Mendix mudaram, arquivos, diagnósticos, conflitos e `state`); `sync/document`
  responde o estado de um artefato por `unit_id` ou `path` Ruby.
- **Conversão.** `project/convert` com `link: true` já vincula o novo projeto.

## Uso em requisição única

`Mxrb::Studio::Backend#call` aceita um objeto de requisição com um nome de
`action` da versão 1 (`catalog`, `file_read`, `model_apply`, ...) e chega aos
mesmos métodos, para clientes que iniciam um processo por requisição.

## Painéis do Studio Pro

Os painéis iniciais Ruby App Explorer e MXRB Tasks estão em
`frontend/modeler/src/studio`, com entrada `studio.html`. Compile usando
`npm run build:studio` em `frontend/modeler`; Node é dependência somente de build.
Os outros bundles do modeler são preservados por uma configuração Vite separada.

O transporte é `chrome.webview`: o host desktop mantém o processo Ruby e fornece
`host/context`/`host/contextChanged` com `root`, `source_model`, `ruby_root` opcional
e variáveis CSS de tema `--studio-*`. Essas mensagens pertencem ao host, não ao
serviço Ruby. O Explorer oferece descoberta/conversão de vínculo, leitura de pastas
sob demanda, linhas virtualizadas e prévia explicitamente somente leitura. Tarefas
usam o catálogo e os argumentos reais, saída e cancelamento. Registro no dock,
criação/renomeação/worktrees na interface, tarefas salvas, editor Ruby nativo e
resolução de conflitos continuam pendentes. Os cenários
`spec/fixtures/frontend_browser/studio_panels*_flow.json` validam o escopo inicial
com arquivos sintéticos e não certificam paridade completa da IDE.

Antes de cada tarefa, o painel consulta `project/status` quando o host não fornece
`ruby_root`. Assim, uma conversão ou vínculo feito em outro dock define a pasta de
execução e a substituição `{ruby}` imediatamente. `{root}` acompanha essa pasta;
`{mpr}` continua apontando para o modelo nativo. Sem vínculo, comandos nativos ou
globais podem usar a pasta de origem; comandos do contexto Ruby pedem conversão ou
vínculo primeiro. Trocar de projeto ou pressionar Stop cancela também a consulta
pendente. Os testes estão em `npm run test:studio`, em `frontend/modeler`, e no
cenário `studio_tasks_linked_flow.json`, que executa `project inspect` num projeto
sintético vinculado com módulo `Shop`, recebendo do host somente o contexto nativo.

O host pode publicar `project_revision` numérico em `host/contextChanged` quando
uma conversão ou mudança de vínculo mantém o mesmo `source_model`. O Explorer
consulta novamente `project/status`, descarta seleção/listagem anteriores e
Tasks cancela a operação pendente. O host nativo usa essa revisão para invalidar
o contexto, sem manter `ruby_root` como cache permanente do vínculo.
O cenário `studio_project_revision_flow.json` verifica essa transição e o
cancelamento de respostas antigas com o host sintético servido por
`node frontend/modeler/test/studio/contextRevisionServer.mjs 4587`. O mesmo
servidor atende `/studio.html?fixture=sync` para os cenários
`studio_sync_preview*_flow.json`. Os hosts sintéticos são fontes TypeScript em
`spec/fixtures/frontend_browser`, sem tipos na hora de servir.

[Voltar ao índice da documentação](README.md)
