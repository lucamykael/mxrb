# Backlog do MXRB

Atualizado em 18 de novembro de 2026. Lote iniciado após `1151aec` (PR #258)
e entregue no [PR #259](https://github.com/lucamykael/mxrb/pull/259).

## Demandas

| Demanda | Prioridade | Status | Resultado verificado |
|---|---|---|---|
| MXRB-001 Preservar o destino do chamador na falha de compilação | P0 | Concluída | `RubyApp::Compilation` mantém `MXRB_OUTPUT_PATH`, inclusive quando o manifesto falha. |
| MXRB-002 Impedir falsos positivos no oráculo MxBuild | P0 | Concluída | Recusa timeout, pacote antigo/vazio, falha sem diagnóstico e novos erros; registra tamanho e SHA-256 dos pacotes. |
| MXRB-003 Validar entradas antes de copiar projetos | P0 | Concluída | Recusa labels/caminhos inválidos, duplicatas e arquivos ausentes antes de criar saída; preserva a origem. |
| MXRB-004 Tornar verificações locais e CI reproduzíveis | P1 | Concluída | JDK 21 explícito, instalação por lockfile, testes Studio, build reproduzível, lint, cobertura integral e Chromium. |
| MXRB-005 Versionar o budget de desempenho | P1 | Concluída | Medianas de três amostras, identidade exata de modelo/assets/ambiente e limites por etapa e total. |
| MXRB-006 Certificar edições em projetos reais | P1 | Concluída | Página, layout e snippet nas famílias 7, 9 e 11 pelo Ruby público; comparação integral e pacotes nativos positivos. |
| MXRB-007 Eliminar o alerta transitivo de picomatch | P2 | Concluída | esbuild substitui Vite/plugin no modeler; auditoria completa com zero vulnerabilidades e quatro interfaces verificadas. |
| MXRB-008 Completar a projeção pública Mendix 7 | P1 | Concluída | `Widget`/`FooterWidget` singulares, contêineres, `EntityPath` e apresentação legada preservados e editáveis. |
| MXRB-009 Certificar comportamento e persistência | P1 | Concluída | Sudoku com 43 passos; persistência com 26 passos, recarga, validação visível e nenhuma gravação inválida. |
| MXRB-010 Aplicar budget calibrado no CI | P1 | Concluída | Gate obrigatório em todo PR/push para main; cinco classes de CPU medidas, 54 amostras e falha explícita em regressão/incompatibilidade. |

## Certificação nativa

A comparação estrutural fixa três repositórios/revisões e reconstrói sem cópia
de runtime. A origem é preservada e a edição resultante deve coincidir com o
modelo esperado, sem alterações adicionais. Os três casos de apresentação
usam `--require-build`: falhas equivalentes não atendem ao aceite.

- Mendix 7.5: 20 bibliotecas Java declaradas pela fixture, fixadas por hash;
  87 fontes Java compilados e pacotes de origem/edição gerados por MxBuild.
- Mendix 9.6: Atlas Core 3.0.7, Atlas Web Content 3.0.6, AnyChart 3.0.2 e
  Data Widgets 2.0.1 restaurados de distribuições oficiais verificadas.
  A configuração `theme/web/settings.json` habilita layouts flexíveis e o
  arquivo de variáveis importa os padrões Atlas. Todos os documentos e
  pesos originais são preservados; nenhuma remoção de erro por exclusão.
- Mendix 11.12.1: `mx check` sem erros, ambos os pacotes completos gerados,
  apresentação e gameplay conferidos em Chromium.

Os [relatórios do lote](../evidence/backlog-2026-11-18.json) distinguem
comparação estrutural, build nativo, navegador e cada run remoto.
O [guia de certificação](../guides/certificacao-edicoes.pt-BR.md) documenta
os comandos, fixtures e recursos necessários. Os casos legados anteriores
continuam distinguindo `pass` de `equivalent`; equivalência não é certificação
de pacote executável.

## Dependências e interfaces

`picomatch` não tinha versão corrigida no registro. A solução removeu a cadeia
Vite/plugin/tinyglobby/fdir/picomatch do modeler e adotou esbuild 0.28.2.
O lockfile e os assets distribuídos na gem foram atualizados. Não há downgrade,
supressão de alertas nem exclusão das dependências de desenvolvimento da auditoria.

O build produz quatro entradas HTML, preserva os outros bundles ao recompilar
apenas Studio e gera arquivos idênticos em builds limpos. O servidor de
desenvolvimento encaminha `/api` ao Ruby e recarrega alterações. Foram verificados
os 28 testes Studio, o contrato do build, os fluxos Chromium de domínio,
catálogo, UML e Studio, e o servidor de desenvolvimento. As aplicações Ruby
exportadas mantêm seu próprio frontend Vite; a troca cobre o workspace modeler.
Dependabot diário e auditoria completa permanecem ativos.

## Desempenho

O [budget local](../benchmarks/sudoku-linux-ruby4.json) continua separado do
[catálogo de CI](../benchmarks/sudoku-ci.json). O catálogo usa Ubuntu 24.04,
Ruby 4.0.5, quatro processadores e a fixture Sudoku fixada. Cada uma das cinco
classes de CPU possui pelo menos três relatórios independentes de três amostras;
Xeon 6975P-C foi medido duas vezes. Os [54 resultados](../evidence/benchmark-ci-2026-11-18.json)
registram imagens dos runners e hashes das fontes.

A margem de 50% incide sobre a maior mediana observada de cada métrica.
`CI / performance / benchmark` seleciona exatamente uma identidade compatível,
verifica sete etapas e total e publica medições/diagnósticos mesmo na falha.
O check obrigatório `test` exige que esse job termine com sucesso.
Ambiente desconhecido, catálogo ambíguo e arquivo ausente falham; não há fallback
local nem recalibração automática. Consulte o [guia](../guides/benchmark-budget.pt-BR.md).

## Verificações

A suíte completa passou localmente com 3.249 exemplos, zero falhas e 100% de
linhas/branches. O CI passou com 3.259 exemplos, JDK 21 e as fixtures públicas
fixadas, exigindo cobertura integral.
A continuação acrescentou testes de scripts, seleção de budgets e build.
A certificação Windows geral gerou 26 casos sem falhas e executou os cenários
de Runtime/navegador. Evidências e contagens finais constam no relatório do lote.

Os gates exigem `MXRB_ACCEPTANCE_MPRS` e `MXRB_CONNECTOR_FIXTURE`, JDK 21,
Chromium e loopback. Falhas não são substituídas por skips. Na execução remota,
o prazo de inicialização do DevTools passou de cinco para trinta segundos,
sem relaxar as verificações funcionais nem os erros de console.

O gate Windows recebe o JDK 21 explicitamente e valida `java` e `javac`.
Uma sondagem expirada ou uma versão incompatível falha antes dos builds;
a seleção não recorre silenciosamente ao JDK 17 do PATH. O teste PowerShell
reproduz timeout, runtime/compilador incorretos e erro de execução.
