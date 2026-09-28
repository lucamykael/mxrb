# Matriz de validação do MXRB

**Português** · [English](../en-US/validation-matrix.md) · [Deutsch](../de-DE/validation-matrix.md)

Última atualização: 25 de setembro de 2026.

O pipeline validado é:

```text
MPR original → validate → export → generate → validate → compare
```

Os originais nunca são modificados.

| Projeto | Mendix | Formato | Resultado |
|---|---:|---|---|
| QueryApiBlogPost | 7.17.0-rc5 | v1 | passou |
| Sudoku | 11.12.1 | v2 | passou; 409 `.mxunit` |
| MendixApp | 9.6.1 | v1 | passou |
| ConnectorKitDemo | 7.5.0 | v1 | passou |
| TreeviewDemo | 5.21.4 | v1 | passou |
| GridViewPlayground | 6.10.8 | v1 | passou |

Em 13 de setembro, `script/validate_matrix` repetiu a matriz com **6/6
passes**: 1.506 units, 1.734 artefatos e 3.388 referências em 19,278 s.

## Inventário adicional local

`script/certify_mprs --cycles 2 --repair-hashes` certificou outros sete MPRs
em 14 roundtrips consecutivos: **7/7 passes**, 2.799 units, 3.238 artefatos e
4.819 referências em 100,544 s. Foram cobertos LearnNow, SLATaskApp, SLATaskAppNative,
MyFirstModule, CourseManager, RubyBridgeSandbox e VetClinic.

SLATaskApp tinha um hash de conteúdo obsoleto e RubyBridgeSandbox tinha dois.
O gate reparou somente `Unit.ContentsHash` em cópias temporárias, registrou os
UUIDs alterados e preservou os bytes BSON originais. Os arquivos-fonte não
foram modificados. O segundo roundtrip também detectou e corrigiu tipos de
widgets nativos desserializados como strings.

A recertificação de 13 de setembro encontrou e corrigiu mais duas perdas reais:
o DSL acrescentava `System.Administrator` a uma lista de papéis nativos que não
o continha, e o codec de settings 11 ainda não reconhecia
`Settings$ConstantValue`, `Settings$SharedValue` e `Settings$PrivateValue`.
Testes focados cobrem as duas regressões; valores privados não são publicados.

Em 25 de setembro, `script/validate_ruby_app --repair-hashes` certificou o
corpus completo de 13 projetos por exportação Ruby app, auditoria da fonte
pública com zero violações, compilação com o sidecar Mendix editável destacado,
validação do MPR e comparação semântica idêntica: **13/13 passaram**. O reparo
de hashes continua explícito e temporário: uma unit do SLATaskApp e duas do
RubyBridgeSandbox foram corrigidas em cópias; os outros onze projetos não
precisaram de reparo.

Esse gate encontrou e corrigiu vazamentos que o round-trip estrutural não
detectava. Mapeamentos do Database Connector agora usam blocos de parâmetros
ordenados; escalares, ações, fontes XPath e listas de objetos pluggable
suportados pelo schema usam builders semânticos editáveis, enquanto qualquer
valor aninhado ainda não representado permanece íntegro no baseline privado; e
design properties compostas usam declarações semânticas aninhadas, com
identidades BSON restauradas privadamente. UUIDs externos de configuração de
widgets deixaram de ser confundidos com identidade de unit.

## Cobertura profunda editável

O comparador cobre metadados, segurança, árvore de units, entidades, access
rules, associações, páginas, widgets, eventos, menus e corpos completos de
microflows/nanoflows. UUIDs e coordenadas visuais são normalizados.

Os 264 corpos de flows da matriz são emitidos como Ruby tipado. As 133 páginas
contêm 1.304 nós de 25 tipos; estruturas profundas permanecem hashes Ruby
editáveis. Toda unit nativa mantém o baseline JSON e também é expandida em
`.mxrb/native_units.rb`, inclusive conteúdo sem DSL concisa.

## Validação oficial 11.12.1

- `mx show-version` reconheceu o MPR reconstruído;
- `mx check` terminou com **0 erros**;
- original e reconstruído: **23 warnings, 1 depreciação e 6 recomendações**;
- `mxbuild --target=package`: **BUILD SUCCEEDED**;
- MDA atual: 11.941.148 bytes, SHA-256
  `fc4fb7a2ea2b4ad7cdb0fcd3296a5dbb5c4d148371aad997ab0032d2c5c0cf33`.

O gate dedicado de constantes materializou string, boolean, DateTime, decimal
e integer/long, fez dois ciclos MPR → Ruby → MPR com IDs estáveis e foi
empacotado pelo MxBuild 11.12.1. O caso DateTime usa a representação nativa
`yyyy-MM-ddTHH:mm:ss`; valores privados de configuração permanecem locais e
não são publicados.

O gate de regras de acesso cobre papéis, create/delete, documentação, direitos
padrão, XPath/caption e membros de atributo e associação. Duas ACLs com a mesma
assinatura semântica mantiveram IDs distintos por dois ciclos; referências
qualificadas e identidades de membros também permaneceram estáveis. O MxBuild
11.12.1 empacotou o fixture completo sem erros.

O gate de estruturas de domínio cobre índices `Normal`, `CreatedDate` e
`ChangedDate`, as quatro flags de system members e generalização. Export
Ruby-app e dois ciclos MPR → Ruby → MPR mantiveram semântica, GUIDs e IDs
nativos sem fallback opaco; o MxBuild 11.12.1 terminou com **BUILD
SUCCEEDED**. Os valores armazenados `Association`, `Owner` e `ChangedBy` são
rejeitados para índices porque o próprio `EntityIndex` oficial não consegue
materializá-los.

O gate de lifecycle de entidade cobre os quatro pares before/after e
commit/delete, referência de microflow, passagem do objeto, propagação de
retorno falso e IDs. Ele também verifica leitura e atualização do campo legado
`Event`, enquanto novas units usam o nome físico correto `Type`. Ruby-app e
dois ciclos regulares permaneceram idênticos, e o MxBuild 11.12.1 empacotou o
fixture completo sem erros.

O gate de module roles cobre nome, descrição, unit e IDs de papéis. Ruby-app e
dois ciclos regulares mantiveram comparação idêntica sem fallback opaco; os
project roles do fixture referenciam os papéis certificados e o MxBuild
11.12.1 terminou com **BUILD SUCCEEDED**.

O gate de registros de project security cobre todas as propriedades de user
roles, demo users e política de senha, incluindo IDs e GUIDs. No Ruby-app a
senha é redigida do fonte público e restaurada pelo baseline privado. Dois
ciclos regulares permaneceram idênticos, sem fallback opaco, e o MxBuild
11.12.1 terminou com **BUILD SUCCEEDED**.

## Validação oficial Mendix 5–9

O projeto 6.10 gerou MDA no original e reconstruído. As versões 7.5 e 7.17
chegaram à compilação Java com os mesmos erros de dependências dos originais.
O 9.6.1 manteve paridade de 896 diagnósticos. O 5.21 exato depende de WPF e
Windows; sua paridade foi verificada pelo conversor oficial 6.10 em memória.

## Limite de confiança

A matriz prova os cenários inspecionados, não compatibilidade universal com
todo metamodelo Mendix. Encodings `.mxunit` desconhecidos são rejeitados em vez
de adivinhados. A validação exata do 5.21 em Studio Pro/Windows continua sendo
um limite explícito.

## Certificação de widgets e apresentação

`script/forms_core_project_gate` complementa a matriz de comportamento com um
gate estrutural por propriedade. Para Mendix 11.12.1, ele materializa as 455
ocorrências herdadas dos 41 widgets core, reabre o MPR, exporta Ruby sem
fragmentos opacos, recompila e compara cada valor tipado após nova reabertura.
O resultado atual é 455/455 em `imported` e `compiled`. A contagem
`studio_validated` também é 455/455.

Com `--mxbuild` e o binário oficial 11.12.1, o gate cria um segundo MPR de
evidência com widgets completos nos contextos exigidos de layout, template,
entidade, arquivo e imagem. O MxBuild carregou, verificou e empacotou esse MPR
com `exit_status` 0 e zero problemas. Uma inspeção tipada independente confirma
que as mesmas 455 propriedades estão presentes no projeto aceito. O
`TemplatePlaceholder`, mantido pelo metamodelo mas proibido pelo Studio em
templates implantáveis, fica em um template legado explicitamente excluído;
ele ainda é desserializado pelo oráculo sem fingir que pode ser publicado.

`script/presentation_documents_gate` certifica layouts, page templates,
snippets e building blocks criados pela DSL Forms tipada. Ele exige dois
ciclos Ruby → MPR → Ruby com semântica e IDs nativos estáveis. O MxBuild
11.12.1 oficial empacotou o MPR final com `exit_status` 0 e zero problemas.

O fixture `spec/fixtures/navigation_profiles/project.rb` certifica perfis de
navegação com login traduzido, home/not-found, home por papel e configuração
de partial sync. `script/frontend_acceptance` validou original e reconstruído
com o MxBuild 11.12.1: zero erros, sem diferenças estruturais e
`frontend_ready: true`.

O fixture `spec/fixtures/published_rest/project.rb` cobre REST publicado com
resources, operações, parâmetros e mappings JSON/export inferidos. Dois ciclos
mantiveram IDs e semântica; `script/frontend_acceptance` aprovou original e
reconstruído no MxBuild 11.12.1 com zero erros, zero diferenças estruturais e
`frontend_ready: true`.

O fixture `spec/fixtures/consumed_services/project.rb` cobre chamada REST sem
body com parâmetros, headers, timeout e resposta HTTP, além de serviço OData
consumido com CSDL v4 e URL baseada em constante. Dois ciclos mantiveram IDs e
semântica sem fallback opaco; `script/frontend_acceptance` aprovou original e
reconstruído no MxBuild 11.12.1 com zero erros, zero diferenças estruturais e
`frontend_ready: true`.

O fixture `spec/fixtures/message_xml/project.rb` cobre message definitions,
import/export mappings derivados com `XmlPath` e ações de microflow para
importar e exportar XML. Dois ciclos mantiveram IDs e semântica sem fallback
opaco; `script/frontend_acceptance` aprovou original e reconstruído no MxBuild
11.12.1 com zero erros, zero diferenças estruturais e `frontend_ready: true`.

O fixture `spec/fixtures/published_odata/project.rb` cobre um serviço OData 4
read-only com papel, autenticação Basic, entity type, ID, atributos e entity set
paginado. Dois ciclos mantiveram IDs e semântica sem fallback opaco;
`script/frontend_acceptance` aprovou original e reconstruído no MxBuild 11.12.1
com zero erros, zero diferenças estruturais e `frontend_ready: true`.

`script/certify_widgets --browser-report REPORT.json App.mpr` é o gate para
widgets do compilador web nativo e Marketplace realmente usados. Ele exige,
em conjunto:

- compilação sem fallback de todas as páginas e layouts web;
- resolução de cada ID pluggable para um `.mjs` dentro de MPK, com SHA-256;
- materialização do modelo e build Rspack nativo da versão Mendix;
- relatório Chromium aprovado, sem exceção/fallback visível, declarando todos
  os IDs e tipos de widget exercitados pelo cenário.

Importar um MPK ou concluir o bundle isoladamente não certifica comportamento.
Widgets que exigem datasource, atributo ou posição específica — por exemplo,
filtros dentro de Data Grid/Gallery — só passam quando o cenário os exercita
nesse contexto válido. Pacotes futuros ou ainda não exercitados falham como
evidência ausente, em vez de herdarem uma promessa genérica de compatibilidade.
O frontend React/TypeScript de `--mode ruby` tem uma trilha separada: seu
relatório Chromium certifica os widgets sem afirmar que os componentes
pluggable equivalentes também passaram no Runtime Mendix.

## Índice semântico

Os seis MPRs produziram **1.734 artefatos** e **3.388 referências**. Consultas
de referências, callers, callees, impacto, lint e diff tipado foram exercitadas
sem MDL.

## Avaliações, cobertura e runtime

- 2.110 exemplos, zero falhas;
- 100,00% das linhas: 37.689/37.689;
- 100,00% dos branches: 16.310/16.310;
- avaliação Sudoku: 7/7 checks;
- testes funcionais Sudoku: 3/3 localmente em 34,16 s;
- testes funcionais Sudoku: 3/3 no Docker em 39,52 s.

Asserções Ruby verificam retorno e contagens XPath persistidas: Games 1/2/3 e
Cells 81/162/243. JUnit XML é apenas relatório opcional gerado em Ruby.

O gate 11.12.1 agora inclui navegador Chromium autenticado: login, navegação
Home/Orders, captura determinística de DOM/layout/estilo/ARIA, screenshots,
comparação SHA-256 com baseline explícito, detecção de erros de widget/Runtime
e logout real. Os scaffolds `page --chain` também materializam e passam
preflight nos três caminhos suportados; `page --template` foi exercitado em
Runtime para dashboard e formulário vertical com CSS computado auditado.

Os projetos Mendix reais são entradas externas de certificação e nunca ficam
neste repositório. Defina `MXRB_FIXTURES_ROOT` para `script/validate_matrix`,
`MXRB_BENCHMARK_MPR` para `script/benchmark` e `MXRB_CONNECTOR_FIXTURE` para os
specs opcionais do conector. `MXRB_ACCEPTANCE_MPRS` aceita um ou mais MPRs,
separados pelo separador de paths do sistema, para o gate de compatibilidade
web. A suíte carrega essas quatro chaves do `.env` ignorado sem sobrescrever
variáveis já definidas pelo processo. `.env.example` documenta somente os
nomes; valores específicos da estação devem permanecer no `.env` ignorado ou
no ambiente do shell.

`script/validate_matrix` repetiu os seis round-trips, 1.506 units, em 19,278 s.
Após corrigir a cópia obrigatória de `mprcontents` para MPR v2,
`script/benchmark` executou o pipeline Sudoku três vezes em Ruby 4.0.5. A
mediana foi 9,6308 s no total: validação 0,7596 s, índice frio 0,7839 s,
índice quente 0,0090 s, leitura somente leitura 0,8171 s, exportação 3,9405 s,
geração 2,1941 s e comparação 1,1322 s. O cache quente teve speedup mediano de
87,1×. A medição antiga de 6,8463 s não é um baseline comparável, pois usava
outra composição de etapas e não registrava ambiente/budget; automatizar um
budget versionado continua pendente. O fuzzing
determinístico cobre 250 documentos BSON aninhados e 50 arquivos `.mxunit`
atômicos, inclusive valores binários.
