# Matriz de validação do MXRB

**Português** · [English](../en-US/validation-matrix.md) · [Deutsch](../de-DE/validation-matrix.md)

Última atualização: 11 de agosto de 2026.

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

Em 11 de agosto, `script/validate_matrix` repetiu a matriz com **6/6 passes**:
1.506 units, 1.734 artefatos e 3.388 referências em 16,381 s.

## Inventário adicional local

`script/certify_mprs --cycles 2 --repair-hashes` certificou outros sete MPRs
em 14 roundtrips consecutivos: **7/7 passes**, 2.799 units, 3.238 artefatos e
4.819 referências. Foram cobertos LearnNow, SLATaskApp, SLATaskAppNative,
MyFirstModule, CourseManager, RubyBridgeSandbox e VetClinic.

SLATaskApp tinha um hash de conteúdo obsoleto e RubyBridgeSandbox tinha dois.
O gate reparou somente `Unit.ContentsHash` em cópias temporárias, registrou os
UUIDs alterados e preservou os bytes BSON originais. Os arquivos-fonte não
foram modificados. O segundo roundtrip também detectou e corrigiu tipos de
widgets nativos desserializados como strings.

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

## Certificação de widgets

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

Os seis MPRs produziram **1.778 artefatos** e **3.387 referências**. Consultas
de referências, callers, callees, impacto, lint e diff tipado foram exercitadas
sem MDL.

## Avaliações, cobertura e runtime

- 1.337 exemplos, zero falhas;
- 100% das linhas: 24.082/24.082;
- 100% dos branches: 9.883/9.883;
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
specs opcionais do conector. `.env.example` documenta somente os nomes; valores
específicos da estação devem permanecer no `.env` ignorado ou no ambiente do
shell.

`script/validate_matrix` repetiu os seis round-trips, 1.506 units, em 16,381 s.
`script/benchmark` mediu o pipeline Sudoku completo em 6,8463 s. O fuzzing
determinístico cobre 250 documentos BSON aninhados e 50 arquivos `.mxunit`
atômicos, inclusive valores binários.
