# Matriz de validação do MXRB

**Português** · [English](../en-US/validation-matrix.md) · [Deutsch](../de-DE/validation-matrix.md)

Última atualização: 29 de julho de 2026.

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

## Índice semântico

Os seis MPRs produziram **1.772 artefatos** e **3.330 referências**. Consultas
de referências, callers, callees, impacto, lint e diff tipado foram exercitadas
sem MDL.

## Avaliações, cobertura e runtime

- 432 exemplos, zero falhas;
- 100% das linhas: 5.744/5.744;
- 100% dos branches: 2.190/2.190;
- avaliação Sudoku: 7/7 checks;
- testes funcionais Sudoku: 3/3 localmente em 34,16 s;
- testes funcionais Sudoku: 3/3 no Docker em 39,52 s.

Asserções Ruby verificam retorno e contagens XPath persistidas: Games 1/2/3 e
Cells 81/162/243. JUnit XML é apenas relatório opcional gerado em Ruby.

`script/validate_matrix` repetiu os seis round-trips, 1.506 units, em 13,733 s.
`script/benchmark` mediu o pipeline Sudoku completo em 6,8463 s. O fuzzing
determinístico cobre 250 documentos BSON aninhados e 50 arquivos `.mxunit`
atômicos, inclusive valores binários.
