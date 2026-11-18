# Backlog do MXRB

Atualizado em 18 de novembro de 2026. Esta fila retoma o projeto após
`1151aec` (PR #258), que acrescentou o oráculo MxBuild para reconstruções
Mendix 6–9. Prioridade P0 cobre resultados incorretos dos gates; P1 cobre
reprodutibilidade e novas provas de compatibilidade; P2 cobre acompanhamento.

## Ponto de retomada

As entregas #249–258 ampliaram a reconstrução por `project.rb`, a aplicação
de edições de páginas/layouts/snippets e a comparação de todas as units.
O [CI do último commit](https://github.com/lucamykael/mxrb/actions/runs/42280735604),
a [certificação Windows](https://github.com/lucamykael/mxrb/actions/runs/43914564750)
e o [oráculo legado](https://github.com/lucamykael/mxrb/actions/runs/43918082610)
terminaram com sucesso. Um workflow verde do oráculo pode incluir casos
`equivalent`: a origem e a reconstrução falham igualmente. Isso não demonstra
que esses projetos geram um pacote executável.

No oráculo de 16 de novembro, Mendix 6.10.8 teve `pass`; 7.5.0, 7.17.0 e
9.6.1 tiveram `equivalent`. Esse é o ponto de partida para novas certificações.

## Demandas do lote atual

| Demanda | Prioridade | Status | Critério de aceite |
|---|---|---|---|
| MXRB-001 Preservar o destino do chamador na falha de compilação | P0 | Implementada | Uma falha ao carregar o manifesto mantém `MXRB_OUTPUT_PATH`; regressão reproduzida antes da correção e teste aprovado depois. |
| MXRB-002 Impedir falsos positivos no oráculo MxBuild | P0 | Implementada | Pacotes antigos são removidos antes do build; timeout, ausência de diagnóstico, ausência de pacote e códigos de saída diferentes falham; novos erros CE nunca contam como equivalência. |
| MXRB-003 Validar as entradas do oráculo antes de copiar projetos | P0 | Implementada | Labels `.` e `..`, caminhos, duplicatas sem distinção de maiúsculas e entradas ausentes são recusados antes de criar a saída; teste real reconstrói um MPR sem alterar a origem. |
| MXRB-004 Tornar verificações locais e CI reproduzíveis | P1 | Implementada | JDK 21 explícito no CI; testes Studio executados no CI; dependências instaláveis por `npm ci`; lint aprovado; build e cenários Chromium aprovados; suíte com fixtures fixadas e cobertura integral. |

`MXRB-001` extrai a compilação para `RubyApp::Compilation`, mantendo a API
`Mxrb::RubyApp.compile` e reduzindo o módulo principal dentro do limite do lint.
Projetos gerados em `local-projects/` ficam fora do lint da biblioteca.

`MXRB-004` atualiza Vite para 8.3.8 e DOMPurify para a versão corrigida
resolvida no lockfile, e recompila os recursos distribuídos na gem. A auditoria
de dependências de produção retorna zero vulnerabilidades. O alerta transitivo
de desenvolvimento continua em `MXRB-007`.

## Continuação do lote

### MXRB-005 Budget de desempenho versionado

Prioridade P1. Status: implementada.

`script/benchmark` agora aceita `--runs` e `--budget`, calcula medianas por
etapa e do total e recusa budgets incompatíveis antes de executar o pipeline.
A identidade inclui modelo, assets, Ruby, plataforma, CPU e quantidade de
execuções. O original e `MXRB_OUTPUT_PATH` são preservados.

A [calibração versionada](../benchmarks/sudoku-linux-ruby4.json) usa três
amostras de Sudoku fixado: mediana total de 25,651754 s. Uma segunda execução
teve mediana de 27,512983 s e passou em todos os limites. Os testes cobrem
aprovação, regressão, incompatibilidade, parâmetros inválidos e preservação
da origem. Consulte o [guia](../guides/benchmark-budget.pt-BR.md) e as
[evidências](../evidence/benchmark-budget-2026-11-17.json).

O CI passa a publicar três amostras por execução. Seu limite numérico depende
de calibração no próprio runner; o budget local não é universal.

### MXRB-006 Certificar edições de apresentação em projetos reais

Prioridade P1. Status: certificação estrutural e visual implementada;
oráculo Windows das novas edições pendente de execução.

O gate `script/certify_presentation_edits` certificou uma página, um layout e
um snippet em cada fixture pública fixada das famílias 7, 9 e 11. As três
reconstruções sem cópia de runtime passaram na comparação integral com o
modelo esperado, sem alterar os originais. O resultado registra os campos
modificados e recusa qualquer diferença adicional.

- Mendix 7: página, layout e snippet pelo Ruby público, incluindo `Widget`
  singular e os contêineres internos legados (MXRB-008).
- Mendix 9 e 11: as três edições pelas declarações públicas Ruby.
- Mendix 11: `mx check` 11.12.1 sem erros na origem e na reconstrução; 43
  passos Chromium aprovados, incluindo apresentação, recarga e gameplay.
- Mendix 7 e 9: casos adicionados ao workflow Windows do oráculo. Esses jobs
  ainda precisam executar com este lote; `equivalent` não significa build aprovado.

O [guia de certificação](../guides/certificacao-edicoes.pt-BR.md) apresenta
os comandos e limites. As [evidências por fixture](../evidence/presentation-edits-2026-11-18.json)
separam comparação estrutural, check nativo e navegador.

Em 18 de novembro, as 20 bibliotecas Java declaradas pelo `build.gradle`
da fixture 7.5 foram resolvidas e fixadas por SHA-256 em
`spec/fixtures/presentation_edits/connector-dependencies.json`. O novo
`script/prepare_oracle_dependencies` verificou os downloads e os 87 fontes Java
compilaram com JDK 8 e as APIs do runtime 7.5. Isso ainda não certifica MxBuild.
O workflow restaura essas bibliotecas antes de copiar origem e reconstrução.

Os casos novos usam `--require-build`: `equivalent` falha nesse modo, e o
relatório exige pacote não vazio e registra tamanho/hash. Os casos antigos
continuam distinguindo comparação equivalente de certificação. O relatório
Windows anterior de Mendix 9 identifica tema Atlas incompleto, AnyChart ausente
e pesos de colunas inválidos; não foram removidos documentos para encobrir
esses erros.

Trabalho restante: executar os novos jobs Windows de Mendix 7/9 e resolver os
assets e pesos de colunas restantes do projeto 9 antes de gerar o pacote.
Aceite nativo: evidências por versão com build da origem e da reconstrução, pacote não vazio e diagnósticos registrados. Dependências ainda
ausentes devem permanecer explícitas como bloqueios.

### MXRB-007 Eliminar o alerta transitivo de picomatch

Prioridade P2. Status: bloqueada por correção upstream.

Em 18 de novembro, o registro npm ainda oferece `picomatch` 4.0.7 como versão mais
recente, ainda afetada por
[GHSA-fc5q-39xc-vjpf](https://github.com/advisories/GHSA-fc5q-39xc-vjpf).
O alerta se propaga por `fdir`, `tinyglobby`, Vite e seu plugin React; são cinco
entradas na auditoria completa, com uma causa transitiva comum.

Aceite: atualizar para uma versão corrigida compatível, obter zero alertas na
auditoria completa, executar testes/build e verificar os diagramas no Chromium.
O downgrade automático sugerido pelo npm para Vite 6 não integra esta demanda.

Acompanhamento preparado: Dependabot diário para o modeler e workflow
`dependency-audit.yml`, com auditoria completa e publicação da versão upstream
e do relatório. O gate de auditoria permanece vermelho enquanto houver alertas.
O CI inclui testes Studio, build, catálogo e diagramas em Chromium para validar
as propostas; recursos compilados também precisam acompanhar o lockfile.
As automações passam a operar após publicação na branch padrão.

## Melhorias priorizadas

Ordem recomendada para execução, incluindo as demandas já abertas:

| Ordem | Demanda | Resultado esperado |
|---|---|---|
| 1 | MXRB-008 | Layouts e snippets Mendix 7 editáveis pelo Ruby público. |
| 2 | MXRB-006 | Certificação nativa Windows das edições Mendix 7/9 concluída. |
| 3 | MXRB-009 | Comportamento e persistência verificados no navegador após edições. |
| 4 | MXRB-010 | Regressões de desempenho bloqueadas por um budget calibrado no CI. |
| 5 | MXRB-007 | Correção de dependência detectada automaticamente e atualização validada. |

### MXRB-008 Completar a projeção pública de apresentação do Mendix 7

Prioridade P1. Status: implementada e certificada localmente.

O leitor agora reconhece `Widget` e `FooterWidget` singulares em raízes,
argumentos de layouts, regiões, contêineres, tabelas, abas e colunas. Projeta
classe/style diretamente do documento antigo e interpreta `EntityPath` legado.
Widgets legados sem representação no catálogo Forms 11 preservam seus campos
em `native_widget` inline, sem depender de fragmentos temporários.

A fixture fixada de Mendix 7 exporta o conteúdo dos documentos selecionados e
permite editar layout e snippet em `app/presentation/`. A reconstrução sem
runtime passou na comparação integral com o modelo esperado, preservando a
origem. Mendix 9/11 também passaram. A regressão real integra a suíte por
`MXRB_CONNECTOR_FIXTURE`; não é substituída por skip.

### MXRB-009 Ampliar a certificação de comportamento no navegador

Prioridade P1. Status: implementada e certificada localmente; CI preparado.

O cenário Sudoku editado passou 43 passos Chromium: apresentação e recarga,
início nos três níveis, seleção, dica, desfazer, notas e retorno à tela inicial.
O cenário de persistência usa uma exportação nova de `persistent_page_drafts`,
com banco inicial vazio: altera um rascunho, salva, confere o dado após recarga,
recusa nome vazio com mensagem visível e confirma que nenhuma linha inválida
foi gravada. Ambos exigem ausência de erros inesperados no console.

`script/browser_fixture_gate` inicia o servidor numa porta livre, executa o
cenário e encerra o servidor. O CI executa esses gates, além de catálogo e UML,
e publica relatórios e capturas. Consulte as
[evidências do lote](../evidence/backlog-2026-11-18.json).

### MXRB-010 Aplicar o budget de desempenho no CI

Prioridade P1. Status: calibração e execução estrita preparadas; depende de
medições/publicação no runner.

`script/calibrate_benchmark` exige pelo menos três relatórios compatíveis,
confere amostras/medianas e registra mínimo, máximo, mediana, hashes de origem
e margem explícita. O workflow `pipeline-performance.yml` coleta três
medições de três amostras no Ubuntu 24.04/Ruby 4.0.5 e gera um candidato para
revisão. Seu modo `verify` executa `--budget docs/benchmarks/sudoku-ci.json`
e falha se o arquivo estiver ausente ou incompatível; não há fallback local.

Ainda não existe um budget numérico de CI nem um bloqueio de desempenho
calibrado no workflow principal. Os runs consultados precedem este lote e
não publicaram as novas amostras. É necessário publicar a branch, executar
a calibração no runner, revisar/versionar o resultado e ativá-lo no CI.
Usar os artefatos produzidos por `MXRB-005` para calibrar limites próprios do
ambiente de CI. Registrar a variação entre execuções, escolher uma margem
justificada e versionar o budget compatível com a fixture e o runner.

Aceite: executar o benchmark com `--budget` no CI e falhar quando uma etapa ou
o total ultrapassar o limite; publicar medições e diagnóstico da regressão.
Mudanças de fixture ou ambiente devem exigir revisão da calibração, sem
reutilizar silenciosamente o baseline local ou desativar o gate.

## Verificação do lote

Em 17 de novembro, a suíte completa passou com 3.245 exemplos e zero falhas,
100% de linhas (52.359/52.359) e branches (23.073/23.073), usando JDK 21 e
as fixtures fixadas. O lint passou em 941 arquivos. Os seis testes de
documentação passaram após atualizar a matriz nos três idiomas. Os 28 testes
Studio, o build do modeler e os cenários anteriores já haviam passado;
esta continuação acrescentou o cenário Chromium de sete passos para Sudoku.

Os testes de regressão estão em `spec/ruby_app_edge_contracts_spec.rb`,
`spec/mxbuild_oracle_spec.rb`, `spec/mxbuild_oracle_inputs_spec.rb`,
`spec/pipeline_benchmark_spec.rb` e `spec/presentation_edit_certification_spec.rb`.
Os cenários `modeler_catalog_flow.json`, `uml_diagrams_flow.json` e
`presentation_edits_sudoku_flow.json` ficam em `spec/fixtures/frontend_browser/`.

Para a suíte completa, disponibilizar as fixtures nas revisões fixadas no
workflow CI e definir `MXRB_ACCEPTANCE_MPRS` e `MXRB_CONNECTOR_FIXTURE`.
O teste de integração do sidecar requer `java` e `javac` do JDK 21 no `PATH`;
os testes HTTP exigem sockets de loopback. Não substituir falhas desses gates
por skips para obter um resultado verde.

## Verificação da continuação de 18 de novembro

A suíte completa passou com 3.249 exemplos e zero falhas, com 100% de linhas
(52.371/52.371) e branches (23.079/23.079), usando JDK 21 e fixtures fixadas.
Após os ajustes adicionais dos scripts, 15 testes de oráculo, dependências e
calibração também passaram. As três certificações estruturais passaram;
`mx check` 11.12.1 não encontrou erros na origem nem na reconstrução.
Os 28 testes Studio, build do modeler e os quatro cenários Chromium passaram.
O lint passou em 947 arquivos; os seis testes de documentação passaram.

Não foi publicado commit/PR nem executado um novo job remoto nesta continuação.
MXRB-006, MXRB-007 e MXRB-010 continuam abertos nos pontos externos descritos
acima; a evidência local não é usada para declará-los concluídos.
