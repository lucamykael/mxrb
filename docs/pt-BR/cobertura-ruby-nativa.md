# Cobertura Ruby nativa

Esta é a fonte de verdade para a expansão do compilador Ruby → Mendix. Uma
superfície só recebe o estado `native` quando possui testes de criar, alterar,
remover, reabrir o MPR e recompilar sem trocar identidades nativas. Preservar o
BSON no sidecar não conta como edição.

Estados:

- `native`: Ruby autoritativo materializa e atualiza o artefato no Studio Pro;
- `parcial`: existe projeção nativa, mas nem todas as variantes são editáveis;
- `preserved_native`: round-trip preserva o artefato opaco;
- `runtime_only`: executa no runtime MXRB, sem equivalente nativo automático.

| Superfície | Estado | Contrato atual / próximo gate |
|---|---|---|
| Entidades e DTOs não persistentes | native | criar/remover, persistência estável |
| Atributos | native | tipos, required, unique, default, docs, length, localize date e referência de enum |
| Associações locais e cross-module | native | criar/alterar/remover, tipo, owner, storage, docs, delete behavior e ID estável |
| Definições de enumeração | preserved_native | próximo: valores, captions traduzidas, documentação e ID |
| Constantes | preserved_native | próximo: tipo, valor padrão, documentação e ID |
| Regras de acesso de entidade | preserved_native | próximo: roles, CRUD, XPath, direitos default e member access |
| Índices, system members, generalização e OQL view | preserved_native | projetar contrato Ruby autoritativo e regressão por versão |
| Lifecycle de entidade | parcial | callbacks cobertos; ampliar variantes e validação de handlers |
| Module roles e project security | preserved_native | roles, user roles, demo users e configurações por versão |
| Microflows e nanoflows | parcial | grafo e ações mapeadas são native; ampliar todas as famílias de ações/eventos/splits |
| Páginas core | parcial | Page.native e widgets mapeados; ampliar propriedades, data sources, events e validações |
| Layouts, snippets, building blocks e menus | preserved_native | criar projeções Ruby e sincronizadores incrementais |
| Navegação | parcial | itens de Page.native; ampliar perfis, home/login e role targeting |
| Pluggable widgets | parcial | pacote MPK e propriedades; ampliar schema, actions e design properties |
| Scheduled events | preserved_native | intervalo, timezone, enablement, handler e identidade |
| REST publicado/consumido | preserved_native | serviços, resources, operations, mappings, auth e contratos |
| OData, App Services e Web Services | preserved_native | contratos publicados/consumidos e versões suportadas |
| Import/export mappings, JSON/XML/message definitions | preserved_native | edição estrutural e referências estáveis |
| Java custom actions e connectors externos | runtime_only | adapter Ruby existe; próximo: documento/action nativo e package contract |
| Workflows e task pages | preserved_native | metamodelo, outcomes, timers, boundaries e segurança |
| Settings, runtime, theme/design system e resources | parcial | assets e tokens cobertos; ampliar settings nativos versionados |
| React/TypeScript convencional | runtime_only | vira nativo apenas como pluggable widget oficial |

## Ordem de implementação

1. domínio completo: associações, enums, constantes, access rules, índices,
   generalização, system members e OQL views;
2. security e operação: roles, demo users, settings e scheduled events;
3. linguagem de flows: ações, eventos, splits, loops, erros e chamadas;
4. UI: pages, layouts, snippets, menus, widgets e propriedades avançadas;
5. integrações: REST/OData/App/Web Services, mappings, Java e connectors;
6. workflows e superfícies restantes encontradas no corpus real;
7. certificação por versão com `mxbuild`, Studio Pro e comparação semântica.

Cada fase deve manter o comportamento fail-closed: uma variante desconhecida é
preservada e relatada, nunca silenciosamente convertida nem descartada.
