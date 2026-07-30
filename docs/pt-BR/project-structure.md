# Estrutura do projeto exportado

**Português** · [English](../en-US/project-structure.md) · [Deutsch](../de-DE/project-structure.md)

A árvore produzida por `mxrb export` separa políticas globais, comportamento
dos módulos, unidades nativas preservadas e assets:

```text
project.rb
.mxrb/{native_units.json,native_units.rb,assets.json}
app/{security,navigation,design_system}/
modules/NomeDoModulo/{domain,application,presentation,infrastructure,security}/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` orquestra o carregamento. Os módulos contêm o comportamento. O
manifesto nativo preserva estruturas ainda sem DSL concisa; o manifesto de
assets registra caminho relativo, tamanho e SHA-256 de cada arquivo.

Na reconstrução, caminhos absolutos, traversal com `..`, arquivos ausentes e
checksums divergentes falham de forma segura. Somente entradas declaradas no
manifesto são gravadas.

A estrutura suporta Ruby para um Mendix novo, Ruby sobre baseline exportado,
Mendix para Ruby editável e Mendix → Ruby → Mendix estruturalmente equivalente.

[Voltar ao índice](README.md)
