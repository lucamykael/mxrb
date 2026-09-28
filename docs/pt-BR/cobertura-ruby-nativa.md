# Cobertura Ruby nativa

Esta é a fonte de verdade para a expansão do compilador Ruby → Mendix. Uma
superfície só recebe o estado `native` quando possui testes de criar, alterar,
remover, reabrir o MPR e recompilar sem trocar identidades nativas. Preservar o
BSON no sidecar não conta como edição.

Atualização de 28 de setembro de 2026: a matriz abaixo é conservadora por
família, não uma porcentagem de conclusão. Domínio, segurança e operação já
possuem rotas de autoria incremental; variantes não representadas continuam
preservadas. Os contratos e limites verificados estão na
[revisão de Ruby e round-trip](../reviews/ruby-code-review-2026-09-05.pt-BR.md).

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
| Definições de enumeração | native | criar/renomear/remover, valores ordenados, captions por idioma, documentação e IDs estáveis |
| Constantes | native | cinco tipos oficiais, valor padrão, exposição ao cliente, metadados e IDs estáveis; overrides privados não vazam |
| Regras de acesso de entidade | native | roles, CRUD, documentação, direitos padrão, XPath/caption, membros de atributo/associação e IDs estáveis |
| Índices, system members e generalização | native | índices `Normal`, `CreatedDate` e `ChangedDate`; flags de auditoria, herança e IDs estáveis |
| OQL view | native | source document, valores e associações OQL com IDs estáveis |
| Lifecycle de entidade | native | before/after commit/delete, microflow, flags e IDs estáveis |
| Module roles | native | nome, descrição, criação/alteração/remoção e IDs estáveis |
| Project roles, demo users e política de senha | native | propriedades, relações, IDs/GUIDs estáveis e segredos privados |
| Settings globais e access containers de project security | native | opções globais, senha administrativa privada e ACLs de FileDocument/Image com IDs estáveis |
| Microflows e nanoflows | parcial | grafo e ações mapeadas são native; ampliar todas as famílias de ações/eventos/splits |
| Páginas core | parcial | 41 widgets e 455 ocorrências passam MPR → Ruby → MPR e MxBuild 11.12.1; falta ampliar o runtime funcional |
| Layouts, page templates, snippets e building blocks | native | DSL Forms tipada; criar/alterar/remover, dois ciclos com IDs estáveis e MxBuild 11.12.1 sem problemas |
| Menus | parcial | captions localizadas, page/microflow, ícones, hierarquia e remoção autoritativa; ações desconhecidas ficam em fallback lossless |
| Navegação | parcial | perfis modernos e legados, home/login/not-found, títulos, flags offline e homes por papel; PWA e configurações offline desconhecidas permanecem opacas |
| Pluggable widgets | parcial | pacote MPK e propriedades; ampliar schema, actions e design properties |
| Scheduled events | native | minuto/hora/dia/semana, offsets, weekdays, overlap, fuso, enablement e IDs estáveis |
| Expressões regulares | native | texto Mendix/JVM, criação, edição, remoção e renomeação não referenciada com identidade privada |
| REST publicado e mappings JSON | parcial | serviço, resources, operações, parâmetros, JSON/export mappings e autenticação suportada; variantes desconhecidas ficam lossless |
| REST consumido e OData consumido | parcial | chamadas REST tipadas e serviço OData básico com CSDL v4; ampliar auth, proxy, form-data e entidades validadas |
| OData publicado | parcial | OData 4 read-only com entity types, IDs, atributos e entity sets; ampliar escrita, ações, enums e associações |
| App Services e Web Services | parcial | serviços consumidos, ações/parâmetros e SOAP publicado com versões/operações escalares; contratos MSD e entidades estruturadas seguem lossless |
| Message definitions e mappings XML derivados | parcial | entidades/atributos expostos, import/export mappings e ações XML; ampliar árvores, associações e variantes |
| XSD/WSDL e outros import/export mappings | parcial | XSD e WSDL consumido com conteúdos/namespace/localização e mappings referenciados; ampliar serviços WSDL interpretados e árvores complexas |
| Java e JavaScript custom actions | native | assinaturas tipadas, scaffolds com fontes preservadas e pacotes compilados pelo MxBuild 11.12.1 |
| Connectors externos | parcial | auditoria e instalação por pacote oficial verificado; módulos protegidos continuam tratados como dependência externa |
| Workflows e task pages | parcial | contexto, start/end, single user task, página parametrizada, XPath e outcome simples; ampliar fluxos de outcome, timers, boundaries e segurança |
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

## Cobertura verificável atual

A suíte estrita passou com 2.111 exemplos e mede 100,00% das
linhas (37.689/37.689) e 100,00% dos branches (16.310/16.310). Nenhum código
executável da biblioteca foi removido do denominador para atingir o gate. O CI
exige o mesmo piso de 100/100.

Cobertura de código 100/100 também não encerra cobertura funcional: workflows
e task pages agora possuem um recorte tipado `parcial`; integrações e várias
outras famílias também seguem `parcial`; as 455 propriedades de Forms estão em
455/455 no gate independente `studio_validated`.

## Constantes

`constant` cobre os cinco tipos aceitos pelo Mendix 11: string, boolean,
DateTime, decimal e integer/long. Valor padrão, documentação, export level,
estado excluído e exposição ao cliente são editáveis. Dois ciclos MPR → Ruby →
MPR mantêm semântica, UnitID e ID do tipo sem recorrer a BSON opaco. O gate
também exercita a grafia exportada `:date_time`; ela é normalizada para o tipo
nativo sem perder identidade.

O fixture com os cinco tipos foi empacotado pelo MxBuild 11.12.1. O valor de
DateTime usa o formato nativo `yyyy-MM-ddTHH:mm:ss`, exigido pelo validador do
Studio Pro. Overrides de configuração privados continuam no sidecar local e
seus valores não aparecem no Ruby público.

## Regras de acesso de entidade

`access_rule` cobre todas as propriedades do `DomainModels$AccessRule` e do
`DomainModels$MemberAccess` no Mendix 11: papéis de módulo, create/delete,
documentação, direito padrão, XPath e caption, além de direitos `None`,
`ReadOnly` e `ReadWrite` para atributos e associações, inclusive membros
herdados com referência qualificada.

Dois ciclos MPR → Ruby → MPR preservam a semântica e os IDs de regras e
membros. O gate inclui duas ACLs com a mesma assinatura papel/XPath: a DSL MPR
mantém os IDs explícitos, enquanto o modo Ruby app usa identidades privadas
estáveis e não publica UUIDs. Criação, edição e remoção autoritativa já são
cobertas pelos testes de reconciliação. O fixture completo foi empacotado com
sucesso pelo MxBuild 11.12.1 sem fallback opaco.

## Índices, system members e generalização

Índices cobrem os três tipos que o Studio Pro 11.12.1 consegue materializar:
atributos normais, `CreatedDate` e `ChangedDate`, incluindo ordem, direção,
`IncludeInOffline`, GUID e IDs dos membros. `Association`, `Owner` e
`ChangedBy` ainda existem no enum armazenado do Mendix, mas o próprio
`EntityIndex` não consegue resolvê-los; o MXRB agora os rejeita antes de gerar
um MPR inválido.

As quatro flags de system members (`owner`, `created_date`, `changed_date` e
`changed_by`) e generalizações qualificadas também são editáveis. O gate faz
export Ruby-app e dois ciclos MPR → Ruby → MPR, exige comparação idêntica e
IDs estáveis, não aceita fallback BSON opaco e termina com `BUILD SUCCEEDED`
no MxBuild oficial 11.12.1.

## OQL view

`oql_view` cobre a referência `OqlViewEntitySource`; cada atributo materializa
um `OqlViewValue`, e associações usam `OqlViewAssociationSource`. O documento
`ViewEntitySourceDocument` expõe consulta, documentação, exclusão e export
level. Queries inline são normalizadas para um source document nomeado, como o
Studio Pro 11.

O gate executa Ruby-app e dois ciclos regulares, compara o MPR e exige IDs
estáveis para entidade, source, valores, associação, source da associação e
documento OQL, sem fallback opaco. O fixture completo terminou com
`BUILD SUCCEEDED` no MxBuild oficial 11.12.1.

## Lifecycle de entidade

`before_commit`, `after_commit`, `before_delete` e `after_delete` cobrem toda a
matriz nativa de `Moment` e `Type`. Referência de microflow,
`PassEventObject`, `RaiseErrorOnFalse` e ID são editáveis; a coleção é
autoritativa, portanto criação, alteração e remoção não dependem de posição.

O campo moderno do evento é `Type`, conforme o metamodelo 11.12.1. O leitor e
o reconciliador continuam aceitando o `Event` legado, mas novas units não o
emitem — evitando que `Delete` seja reinterpretado como o default `Commit`.
Ruby-app e dois ciclos MPR → Ruby → MPR mantêm comparação idêntica e IDs
estáveis sem fallback opaco. O fixture com os quatro eventos terminou com
`BUILD SUCCEEDED` no MxBuild oficial.

## Module roles

`module_role` cobre toda a estrutura `Security$ModuleRole` do Mendix 11: nome,
descrição e identidade, dentro de uma unit `Security$ModuleSecurity` também
estável. A coleção é autoritativa e os testes de reconciliação cobrem criação,
alteração, remoção e renomeação explícita sem pareamento por posição.

O gate exporta para Ruby-app e para o DSL regular, executa dois ciclos MPR →
Ruby → MPR, verifica a unit e os IDs dos papéis e proíbe fallback opaco. O
fixture referencia os papéis por project roles reais e foi empacotado com
`BUILD SUCCEEDED` no MxBuild 11.12.1.

## Project roles, demo users e política de senha

`user_role` cobre nome, descrição, `CheckSecurity`, GUID, module roles,
manageable roles, `ManageAllRoles` e `ManageUsersWithoutRoles`. Demo users
cobrem nome, entidade, project roles e identidade. A política de senha cobre
comprimento mínimo, dígito, caixa mista e símbolo, com ID estável.

Ruby-app redige a senha do demo user no fonte público (`password: nil`) e a
restaura pelo baseline privado; o valor não vaza durante a exportação. O gate
faz Ruby-app e dois ciclos regulares, exige comparação idêntica, IDs/GUIDs
estáveis e ausência de fallback opaco. O fixture completo foi empacotado pelo
MxBuild 11.12.1 com `BUILD SUCCEEDED`.

## Settings globais e ACLs especiais de project security

`check_security`, `strict_page_url_check`, `strict_mode`, `admin_user` e o
nível de segurança são editáveis nos DSLs regular e Ruby-app. A senha do
administrador é write-only: pode ser definida explicitamente, nunca aparece no
fonte exportado e é restaurada pelo baseline privado. Ausência de declaração
preserva tanto a senha quanto os containers nativos existentes.

`file_document_access_rule` e `image_access_rule` cobrem documentação, criação,
remoção, direitos padrão, XPath/caption, membros e papéis do módulo `System`.
Ruby-app e dois ciclos regulares preservam os IDs dos containers, regras e
membros sem fallback opaco. Fixtures separados para settings e ACLs terminaram
com `BUILD SUCCEEDED` no MxBuild oficial 11.12.1.

## Documentos reutilizáveis de apresentação

`script/presentation_documents_gate` cria layouts, page templates, snippets e
building blocks por DSL Forms tipada, exporta Ruby legível e recompila o MPR por
dois ciclos. O gate exige validação estrutural, documentos semanticamente
estáveis e preservação dos IDs da unidade e dos nós internos. Com
`--mxbuild /caminho/para/mxbuild`, o MxBuild 11.12.1 oficial empacota o artefato
final; o fixture certificado passa com código de saída zero e zero problemas.

Menus semanticamente suportados também são autoritativos: adicionar, alterar e
remover documentos ou itens preserva as identidades compatíveis, inclusive em
dois ciclos. Captions localizadas, destinos page/microflow, glyph icons e itens
recursivos são Ruby legível. Ações ou ícones desconhecidos exportam
`deep_structure` lossless, por isso a família permanece `parcial`. O fixture
`spec/fixtures/menu_documents/project.rb` passou no `script/frontend_acceptance`
com MxBuild 11.12.1 para original e reconstruído, sem erros e sem diferenças
estruturais.

## REST publicado e mappings JSON

O fixture `spec/fixtures/published_rest/project.rb` declara um serviço REST
com resources, operações GET/POST, parâmetros de path, microflows e
status de sucesso. O compilador infere estruturas JSON e export mappings
tipados para retornos de entidade/lista. Dois ciclos Ruby → MPR mantêm os IDs
das units, produzem fonte sem `deep_structure` e permanecem semanticamente
idênticos. O `script/frontend_acceptance` também aprovou original e
reconstruído no MxBuild 11.12.1, com zero erros e `frontend_ready: true`.

O estado permanece `parcial`: apenas shapes reconhecidos são emitidos pela DSL;
operações, autenticação ou mappings ainda não representados continuam no
fallback lossless em vez de serem parcialmente convertidos.

## REST consumido e OData consumido

O fixture `spec/fixtures/consumed_services/project.rb` combina uma chamada
REST GET sem body, parâmetros de URL, headers ordenados, timeout e resposta
HTTP com um serviço OData consumido baseado em CSDL v4 e URL definida por uma
constante Mendix. Dois ciclos Ruby → MPR mantêm semântica e IDs das units sem
`native_fragment`, `deep_structure` ou BSON opaco nas fontes certificadas.
Original e reconstruído também passaram no MxBuild 11.12.1 com zero erros,
zero diferenças estruturais e `frontend_ready: true`.

Chamadas sem body usam o `CustomRequestHandling` vazio observado em projetos
reais. A DSL rejeita mapping sem variável, variável sem mapping e a mistura de
body customizado com export mapping. A família permanece `parcial`: form-data,
variantes de autenticação/proxy, referências de metadata e entidades OData
validadas ainda seguem pelo fallback lossless quando não são reconhecidas.

## Message definitions e mappings XML derivados

O fixture `spec/fixtures/message_xml/project.rb` declara entidade e atributos
expostos por uma `MessageDefinitionCollection`, import/export mappings com
`XmlPath` e duas microflows que importam e exportam XML. Dois ciclos Ruby → MPR
mantêm a semântica e os IDs das units sem `native_document`, `deep_structure`,
`native_fragment` ou BSON opaco nas fontes certificadas. Original e
reconstruído passaram no MxBuild 11.12.1 com zero erros, zero diferenças
estruturais e `frontend_ready: true`.

Mappings baseados em message definitions não ativam validação contra schema,
pois o próprio MxBuild reserva essa opção para mappings XSD. A família segue
`parcial`: árvores aninhadas, associações, conversores, XSD/WSDL e outras
variantes permanecem no fallback lossless até receberem evidência específica.

## App Services e Web Services

Serviços App consumidos agora expõem localização, timeout, metadados da App
Store, ações, parâmetros e retorno pela DSL `consumed_app_service`. Serviços
SOAP publicados expõem versões, namespace, autenticação, operações, parâmetros
escalares e referências de microflow por `published_web_service`. O gate usa
dois ciclos Ruby → MPR, exige comparação idêntica e IDs de units estáveis; o
corpus legado `ConnectorKitDemo` também exporta as formas reconhecidas pela DSL.

A família permanece `parcial`: o contrato MSD incorporado é preservado sem
perdas, e entidades SOAP estruturadas, membros filhos e variantes futuras
continuam no fallback fail-closed até receberem um modelo tipado próprio.

## XSD e mappings associados

`xml_schema` declara arquivos XSD com caminho, conteúdos, target namespace e
formatos localizados. Import/export mappings já podem apontar para o schema e
seu root element pela DSL existente. Dois ciclos Ruby → MPR preservam os IDs e
a comparação semântica; o fixture completo, incluindo o import mapping, foi
empacotado pelo MxBuild 11.12.1 com zero erros.

A implementação também cobre `imported_web_service` com conteúdo WSDL bruto,
schemas incorporados, URL, target namespace e flags de importação/MTOM. Ela usa
os nomes físicos legados `ImportedServiceImpl`, `WsdlDescriptionImpl`,
`WsdlEntryImpl`, `SchemaContentss` e `XmlSchemaContents`, diferentes dos nomes
públicos do Model SDK. A família permanece `parcial` enquanto serviços e
operações WSDL já interpretados, árvores complexas e demais variantes ainda
dependerem do fallback lossless.

## Java e JavaScript custom actions e connectors externos

`java_action` materializa a assinatura nativa, parâmetros, tipos genéricos,
retorno e metadados visuais. O scaffold `mxrb java-action new` cria também a
classe `UserAction` na convenção `javasource/<module>/actions`; exportações
copiam os fontes e dois ciclos Ruby → MPR preservam conteúdo, semântica e IDs.
O fixture completo foi compilado e empacotado pelo MxBuild 11.12.1.

`javascript_action` oferece o mesmo contrato para código cliente, incluindo
plataforma, parâmetros e retorno. `mxrb javascript-action new` cria a fonte em
`javascriptsource/<module>/actions`; dois ciclos preservam o arquivo e a unit,
e o pacote Web certificado também conclui no MxBuild 11.12.1.

Connectors do Marketplace permanecem dependências externas: o MXRB audita GUID
verificado, superfície pública e proveniência, e só instala por adapter oficial
autenticado. Módulos protegidos não são apresentados como editáveis e pedidos
sem pacote resolvido falham fechados.

## Workflows e task pages

`workflow` materializa contexto, templates de nome e descrição, vencimento,
start/end e tarefas humanas simples. Cada `SingleUserTaskActivity` referencia
uma página criada por `page`, cujo parâmetro de objeto pode ser declarado com
`parameter :WorkflowUserTask, entity: 'System.WorkflowUserTask'`; o contrato
inclui targeting XPath, evento `NoEvent` e um outcome com fluxo vazio.

Dois ciclos MPR → Ruby → MPR preservam a semântica e todas as identidades do
workflow e dos nós internos, sem BSON opaco. O fixture completo foi compilado e
empacotado pelo MxBuild 11.12.1. A família permanece `parcial`: tarefas e
targetings alternativos, múltiplos outcomes/fluxos, timers, boundary events,
subprocessos e regras avançadas de segurança continuam no fallback lossless.

## Scheduled events

`scheduled_event` cobre os quatro schedules concretos do Mendix 11: minuto,
hora, dia e semana. Intervalo, offsets, horário, weekdays, fuso, política de
overlap, ativação, handler e metadados são editáveis; dois ciclos preservam as
IDs da unit e do schedule aninhado. Um fixture com os quatro tipos foi
compilado e empacotado pelo MxBuild 11.12.1. Tipos futuros desconhecidos
continuam fail-closed no fallback lossless, sem reduzir a cobertura versionada.

## OData publicado

O fixture `spec/fixtures/published_odata/project.rb` declara um serviço OData 4
read-only com papel permitido, autenticação Basic, entity type, ID, atributos e
entity set paginado com opções de query. Dois ciclos Ruby → MPR mantêm semântica
e IDs das units sem `native_document`, `deep_structure`, `native_fragment` ou
BSON opaco nas fontes certificadas. Original e reconstruído passaram no
MxBuild 11.12.1 com zero erros, zero diferenças estruturais e
`frontend_ready: true`.

A localização termina em `/`, conforme a regra CE6552 do MxBuild. A família
permanece `parcial`: modos de escrita, microflows publicados, enumerações,
associações, GraphQL e outras variantes continuam no fallback lossless até
receberem evidência dedicada.

## Propriedades de Forms core

`script/forms_core_project_gate` cria um MPR 11.12.1 com uma ocorrência
isolada de cada propriedade herdada dos 41 widgets concretos, exporta o modelo
como Ruby legível, recompila e reabre o MPR tipado. O gate cobre 455/455 nas
fases `imported` e `compiled`, além das 455/455 já cobertas por representação,
emissão, transcodificação e round-trip sintético. Um segundo MPR usa witnesses
completos nos contextos de layout, template, entidade, arquivo e imagem. O
MxBuild 11.12.1 oficial o empacota com zero problemas, e a inspeção tipada desse
mesmo artefato certifica `studio_validated` em 455/455. O `TemplatePlaceholder`
legado é carregado em um template explicitamente excluído, pois o próprio
Studio o proíbe em documentos implantáveis.

## Enumerações em aplicações Ruby

O export `--mode ruby` cria uma classe em `app/enumerations/<módulo>/`. Os IDs
nativos permanecem no vínculo privado do projeto exportado; não são
necessários nas declarações geradas:

```ruby
module Pedidos
  class Status < Mxrb::RubyApp::Enumeration
    mendix_name 'Pedidos.Status'
    documentation 'Situação atual do pedido'

    value 'Aberto' do
      translation 'en_US', 'Open'
      translation 'pt_BR', 'Aberto'
    end
    value 'Fechado' do
      translation 'en_US', 'Closed'
      translation 'pt_BR', 'Fechado'
    end
  end
end
```

`id:` e `captions:` continuam aceitos por compatibilidade. Use
`value 'Novo', renamed_from: 'Anterior'` para renomear um valor sem publicar
seu ID. `remove_value 'Anterior'` desambigua remoção seguida de inserção; sem
uma indicação inequívoca, a operação é recusada. A ordem das
chamadas `value` é autoritativa. Remover o arquivo exclui a enumeração somente
quando não há atributo que a referencie; caso contrário a compilação falha antes
de escrever uma remoção insegura. Estruturas de localização e campos BSON não
representados na DSL são preservados pelo merge incremental.
