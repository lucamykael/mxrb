# Budget do pipeline de benchmark

`script/benchmark` mede validação, índice frio/quente/somente leitura,
exportação, geração e comparação. Cada amostra usa um cache temporário novo;
o MPR original, suas units e seus assets são conferidos por SHA-256 ao final.
`MXRB_OUTPUT_PATH` do chamador é restaurado mesmo quando a geração falha.

```sh
MXRB_BENCHMARK_MPR=/caminho/Sudoku/Sudoku.mpr \
  bundle exec ruby script/benchmark --runs 3 > /tmp/benchmark.json

MXRB_BENCHMARK_MPR=/caminho/Sudoku/Sudoku.mpr \
  bundle exec ruby script/benchmark --runs 3 \
  --budget docs/benchmarks/sudoku-linux-ruby4.json
```

O padrão é três execuções; `--runs` aceita inteiros de 1 a 100. O relatório
mantém as amostras individuais e apresenta a mediana de cada etapa. O total é
a mediana dos totais de cada amostra, não a soma das medianas das etapas.

## Compatibilidade e limites

O arquivo [versionado](../benchmarks/sudoku-linux-ruby4.json) tem
`schema_version: 1`, uma seção `compatibility` e `limits_seconds`.
Todos os sete nomes de etapas e `total` devem ter limites numéricos positivos.
Campos ausentes, nomes desconhecidos e valores inválidos são recusados.

A compatibilidade exige o mesmo protocolo de medição, nome/checksum do modelo,
checksum dos assets, Ruby, plataforma, modelo de CPU, quantidade de processadores
e número de execuções. Uma divergência aborta antes de rodar o pipeline. O caminho
absoluto da fixture não participa dessa identidade, permitindo checkouts separados.

- Código 0: execução concluída e, se solicitado, budget aprovado.
- Código 1: um ou mais limites excedidos, com `budget.exceeded` no JSON.
- Código 2: opções, JSON ou compatibilidade do budget inválidos.
- Falhas de validação ou round-trip abortam a execução; não contam como medição aprovada.

O budget inicial é uma calibração local de Sudoku na revisão
`918af72e43ca8e1d61fb0c32ad13d8da94b944e2`, em Ruby 4.0.5, Linux x86_64 e Ryzen
5 8500G. Os limites são duas vezes a mediana observada, com piso de 50 ms por
métrica. Essa margem é uma política inicial de detecção de regressão, não uma
promessa de desempenho em outras máquinas. As
[amostras e metadados](../evidence/benchmark-budget-2026-11-17.json) acompanham o budget.

## Calibrar outro ambiente

Execute a fixture fixada sem `--budget`, revise as amostras e registre a
`compatibility` desse relatório num novo arquivo. Defina limites para todas as
métricas e faça outra execução com o novo budget. Não altere a identidade de um
budget antigo apenas para contornar uma recusa de compatibilidade.

O CI publica o artefato `pipeline-benchmark` com três execuções. Ele permite
calibrar um budget próprio do runner; o limite local não é aplicado a máquinas
GitHub com hardware diferente. Os testes do CI verificam deterministicamente
as decisões de aprovação, regressão e incompatibilidade.

## Calibração revisável no GitHub Actions

O workflow `Pipeline performance` permite `calibrate` e `verify`. A calibração
usa Ubuntu 24.04 e Ruby 4.0.5; executa três medições de três amostras, publica
o ambiente do runner e produz um candidato:

```sh
bundle exec ruby script/calibrate_benchmark --margin 1.5 \
  benchmark-1.json benchmark-2.json benchmark-3.json > candidate-budget.json
```

O comando exige identidades iguais, pelo menos três amostras em cada relatório,
métricas positivas e medianas coerentes com as amostras. Arquivos repetidos são
recusados. Registra hashes dos relatórios e mínimo/máximo/mediana entre execuções.
A política inicial aplica 50% de margem sobre a maior mediana observada, por
etapa e para o total. Essa margem é explícita e deve ser revisada à luz da
variação observada entre execuções do runner.

Após conferir artefatos e variação em mais de uma execução, versione o budget
como `docs/benchmarks/sudoku-ci.json`, execute `verify` e acrescente `--budget`
à medição do workflow principal com ambiente compatível. `verify` já exige
esse caminho e falha se estiver ausente/incompatível; publica medições e erros
mesmo quando o comando falha. Nunca recalibra automaticamente durante o gate.

Esse arquivo ainda não foi criado: os runs disponíveis precedem a publicação
das novas medições. O budget local não foi copiado nem usado como limite de CI.
MXRB-010 permanece aberto até a calibração real e a ativação no workflow principal.
