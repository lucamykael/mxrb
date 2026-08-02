# Avaliação de integração das APIs Mendix

Data: 1º de agosto de 2026. Fonte: índice oficial de [APIs e SDKs Mendix](https://docs.mendix.com/apidocs-mxsdk/).

## Matriz de decisão

| API ou SDK | Uso no MXRB | Decisão |
| --- | --- | --- |
| Projects API | listar apps acessíveis e metadados dos projetos | integrada em `team-server projects`; leitura por padrão |
| App Repository API | informações do repositório, branches e commits | integrada na descoberta e clone do Team Server |
| Marketplace Content API | descobrir e baixar módulos/widgets | integrada nas operações de Marketplace |
| Build API | comparar artefato nativo do MXRB com build oficial em nuvem | verificação opcional; nunca dependência do build nativo |
| Deploy API v4 | inventariar apps/ambientes antes da validação de release | adaptador somente leitura proposto; mutações exigem confirmação explícita |
| Pipelines API | iniciar e observar pipeline CI/CD existente | adaptador opt-in proposto, com idempotência e consulta de estado |
| Backups API v2 | listar/criar/baixar snapshots antes de deployment | adaptador de segurança proposto; restore/delete continuam explícitos |
| Runtime API 11 | compilar Java e validar contratos do Runtime | contrato para proxies; é API Java, não substituto REST remoto |
| Client e Pluggable Widget APIs | contratos Dojo/React/Data Grid | referência dos artefatos web gerados, não cliente HTTP |
| Catalog APIs | registrar/consultar fontes governadas | plugin futuro; fora do núcleo build/runtime |
| Model/Platform SDKs e extensibilidade do Studio Pro | modelagem remota ou extensão do Studio Pro | não obrigatórios; MXRB continua Ruby/SQLite/BSON independente |

## Regras de integração

- Chamadas remotas são explícitas; `generate`, `compile`, `validate` e `db up` nunca acessam a Mendix Cloud.
- PATs/API keys vêm de arquivo protegido ou ambiente e nunca entram em relatórios, logs, projetos ou Git.
- Leitura é o padrão. Build, deploy, pipeline, restore, membros e exclusões exigem comando próprio e confirmação proporcional ao impacto.
- A Build API só funciona com apps na Mendix Cloud e usa API key da conta; não substitui o compilador nativo local.
- APIs versionadas de Runtime/frontend são evidência de compatibilidade. O MXRB mantém schemas/seeds exatos e falha fechado sem contrato ou launcher compatível.

## Ordem recomendada

1. Listagem de branches/commits do App Repository no `team-server`.
2. Inventário somente leitura do Deploy e gate opcional de comparação via Build.
3. Estado/disparo de Pipelines com idempotência e polling limitado.
4. Proteções de listar/criar/baixar Backups antes de mutação em nuvem.

Catalog e extensibilidade do Studio Pro ficam em adaptadores separados, pois não reduzem o risco do núcleo nativo.
