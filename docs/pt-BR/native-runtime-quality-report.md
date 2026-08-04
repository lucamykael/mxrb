# Relatório de qualidade do build e Runtime nativos

Data: 4 de agosto de 2026.

## Resultado confirmado

- nenhuma etapa funcional chama `mx`, `mxbuild`, `mxcli`, Studio Pro ou Model SDK;
- build limpo de 12 estágios e geração web passaram em 6.10.8 (39 páginas), 7.5.0 (45), 7.17.0 (66), 9.6.1.29396 (90), 10.24.0.73019 (cliente otimizado) e 11.12.1;
- a matriz de round-trip passou em seis fixtures reais de 5.21.4 a 11.12.1: 1.506 units, 1.734 artefatos e 3.388 referências;
- schemas/seeds auditados do compilador cobrem 6.x, 7.x, 9.x, 10.x e 11.x. 5.x e 8.x falham fechadas na compilação nativa; a Runtime exige o patch exato;
- Data Grid 1 cobre database/XPath/microflow, pesquisa, ordenação, paginação, seleção e botões auditados. Data Grid 2 cobre XPath, colunas de atributo e ação create;
- perfis web: Dojo em 6/7, híbrido Dojo/React em 9, clássico/otimizado conforme o projeto em 10 e React em 11;
- a Projects API inventariou 130 apps. Três projetos Git reais (`MyFirstModule`, `LearnNow Trainning Management` e `SLATaskApp`) passaram validate → export → generate → validate → compare;
- `MyFirstModule` foi regenerado como 11.12.1 exato sem builders proprietários. A Runtime sincronizou 655 operações, criou o administrador `mx` ativo, serviu shell React e login estilizado em `127.0.0.1:18080` e expôs as tabelas esperadas;
- uma aplicação 10.24.0.73019 com cliente otimizado, criada do zero, passou no `mx check` e `mxbuild` oficiais, modelo/Java/Rollup/pacote portátil nativos, 460 operações de sincronização, probe de prontidão e HTTP 200;
- QA final: 1.002 exemplos, zero falhas, 100,00% de linhas (16.917/16.917), 100,00% de branches (6.659/6.659) e RuboCop limpo em 238 arquivos.

## Correções do relatório de melhorias

- geração seletiva de proxies Java para entidades, herança, enumerações e constantes usadas pelo Java customizado;
- lowering da extensão oficial do Database Connector para Java actions do External Database Connector, inclusive `SELECT` seguro do query builder;
- fontes OQL, flags herdadas de persistência, roles de demo user, system texts e storage/access rights exatos;
- readiness estável do PostgreSQL, porta pública loopback (`--runtime-port`), senha administrativa por ambiente e criação do admin;
- recursos de login autossuficientes, placeholders renderizados, cache busting, estilo e i18n;
- hidratação do Atlas CSS, manifest e assets públicos; a homepage real do Team
  Server agora renderiza grids, títulos e botões React acionáveis;
- imports de página no modo developer carregam o token da sessão; o chunk
  corrigido recebe hash de conteúdo e a autoimportação do Rspack compartilha o
  token do entrypoint, eliminando a homepage branca obsoleta sem desabilitar cache;
- o shell gerado fornece um adaptador limitado de `openForm` sobre `openForm2`,
  para que handlers antigos em cache naveguem em vez de falhar silenciosamente
  sem disparar request para a Runtime;
- a Gallery React oficial agora renderiza dados XPath e microflow, templates de
  item, seleção e valores string/numéricos formatados. O QA autenticado mostrou
  título, descrição, `90 day(s)` e `49.95`; a Gallery vazia de Teachers
  permaneceu presente na estrutura;
- fontes nanoflow de lista/objeto e ações de botão agora compilam para os
  contratos reais do cliente Mendix e programas de instruções referenciados por
  função. O subconjunto auditado do grafo inclui decisões, caminhos de erro,
  nanoflows aninhados, ações JavaScript e chamadas de microflow servidor; nós
  não suportados falham fechado em vez de serem tratados como microflows;
- cliques reais no navegador validaram Home → Courses → Add → Save. Formulários
  DataView/TextBox por parâmetro renderizam e persistem valores; create passa o
  GUID por `openForm2`, enquanto a autorização de commit/rollback deriva dos
  module roles da página. O PostgreSQL confirmou os quatro valores de QA salvos;
- proteção contra traversal em templates/imagens/ZIP, identificadores inseguros e symlinks nos inputs nativos;
- comparação normaliza defaults booleanos ausentes do Runtime, restaurando round-trips legados exatos.

## Limites explícitos

1. Widgets Dojo além do Data Grid 1 permanecem listados em `web/mxrb-legacy-pages.json`; não são declarados renderizados.
2. Data Grid 2 cobre o subconjunto auditado XPath/atributo/create. Gallery cobre
   XPath/microflow e o subconjunto auditado do grafo nanoflow. Formatos de grafo
   não suportados, referências ausentes, mapeamentos de parâmetros inseguros e
   instruções cliente não traduzidas ainda falham fechado.
3. As distribuições 6/7/9 instaladas têm bundles exatos, mas não launcher compatível. O launcher 11 exige Java 21 e não inicia 9 com segurança no Java 11. O `db up` legado falha fechado; boot exato é afirmado somente para 10.24.0.73019 e 11.12.1.
4. A Runtime usa licença local trial/developer e emite o aviso esperado de limite de tempo.
5. Build/Deploy/Pipelines/Backups em nuvem são verificações externas opcionais, nunca dependências do build/runtime nativo.

Não existe fallback oculto para `mx`/`mxbuild`.
