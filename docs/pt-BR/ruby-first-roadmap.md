# MXRB: Ruby acima de tudo

**Português** · [English](../en-US/ruby-first-roadmap.md) · [Deutsch](../de-DE/ruby-first-roadmap.md)

## Princípio arquitetural

Ruby é a única linguagem pública do MXRB.

- O modelo Mendix é lido, criado, alterado e analisado por APIs e DSLs Ruby.
- A CLI é apenas uma camada fina sobre essas APIs.
- Não haverá MDL, parser de uma linguagem paralela ou sintaxe própria concorrendo com Ruby.
- Recursos sem abstração concisa continuam sem perdas e editáveis nos Hashes
  Ruby gerados por `native_unit`.
- Studio Pro e MxBuild são validadores externos importantes, mas não são dependências do núcleo Ruby.

## Capacidades

### Disponível

- Leitura e escrita profunda de MPR v1 e v2.
- Exportação de MPR para projeto Ruby editável.
- Geração, validação e comparação estrutural.
- Índice semântico de módulos, entidades, atributos, associações e documentos.
- Consultas Ruby de referências, chamadores, chamadas e impacto transitivo.
- Comandos CLI `refs`, `callers`, `callees` e `impact`, todos delegando à API Ruby.
- Renomeação profunda com prévia Ruby e aplicação explícita.
- Análise estática Ruby de ciclos, alvos ausentes, referências externas,
  artefatos não referenciados e acoplamento entre módulos.
- Regras de lint personalizadas escritas como objetos chamáveis Ruby.
- Diff semântico tipado em Ruby, com mudanças `added`, `removed` e `changed`.
- Navegação estrutural por busca, descrição de relações e árvore semântica.
- Avaliações executáveis de modelo em Ruby, com checks reutilizáveis, severidade,
  score e extensão por blocos Ruby.
- Testes funcionais de microflows definidos em Ruby, instrumentados numa cópia
  descartável e executados pelo runtime Mendix sem JUnit.
- Execução local ou Docker de `mx check`, pacote portátil e runtime, com seleção
  automática da família Java do projeto.
- Gate nativo de 100% de cobertura de linhas para a biblioteca.

## API semântica

```ruby
Mxrb.open("app.mpr") do |project|
  order = project.find_artifact("Sales.Order")
  refs = project.references_to(order)
  callers = project.callers_of("Sales.Recalculate")
  callees = project.callees_of("Sales.Checkout")
  impact = project.impact_of("Sales.Order")

  impact.artifacts.each do |artifact|
    puts "#{artifact.kind}: #{artifact.qualified_name}"
  end
end
```

Os resultados são objetos Ruby imutáveis: `Mxrb::Semantic::Artifact`,
`Mxrb::Semantic::Reference` e `Mxrb::Semantic::Impact`.

Uma renomeação é sempre inspecionável antes da escrita:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plan = project.plan_rename("Sales.Order", to: "Invoice")
  plan.changes.each { |change| puts change.inspect }
  plan.apply!
end
```

Na CLI, `mxrb rename app.mpr Sales.Order Invoice` apenas mostra a prévia.
Acrescente `--apply` para efetivar a alteração.

## Remoção segura

Units independentes, como microflows e páginas, podem ser inspecionadas antes
da remoção:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plano = project.plan_remove("Sales.FluxoSemUso")
  plano.apply! if plano.safe?
end
```

O plano é bloqueado enquanto houver referências recebidas ou units filhas.
Elementos embutidos no domínio exigem sua mutação tipada. Na CLI,
`mxrb remove app.mpr Sales.FluxoSemUso` mostra a prévia e `--apply` só grava
um plano seguro.

## Movimentação segura no módulo

Units independentes podem ser movidas para um módulo ou pasta sem alterar seu
nome qualificado nem suas referências:

```ruby
Mxrb.open("app.mpr", readonly: false) do |project|
  plano = project.plan_move("Sales.Processar", to: "Sales.Automacao")
  plano.apply!
end
```

O plano preserva o tipo nativo de contenção e bloqueia elementos embutidos do
domínio, destinos que não são containers, ciclos de pastas e movimentos entre
módulos. `mxrb move app.mpr Sales.Processar Sales.Automacao` mostra os IDs dos
containers; `--apply` executa a transação.

## Análise estática

```ruby
report = Mxrb.open("app.mpr", &:analyze)

report.errors.each { warn _1.message }
report.unreferenced.each { puts _1.qualified_name }
report.call_cycles.each { puts _1.artifacts.map(&:qualified_name) }
report.module_dependencies.each { puts "#{_1.from} -> #{_1.to}" }
```

Integrações externas desconhecidas geram aviso; um alvo ausente dentro de um
módulo existente gera erro. Referências `System.*` são reconhecidas como parte
da plataforma Mendix.

## Diff semântico

```ruby
result = Mxrb.diff("before.mpr", "after.mpr")

result.added.each { puts _1.path }
result.removed.each { puts _1.path }
result.changed.each { puts "#{_1.before} -> #{_1.after}" }
```

`mxrb diff before.mpr after.mpr` imprime uma mudança tipada por linha, adequada
para logs e revisão em Git. `mxrb compare` continua compatível com a saída
textual anterior.

## Navegação

```ruby
project.search_artifacts("checkout", kind: :microflow)
project.describe_artifact("Sales.Checkout")
```

Os comandos equivalentes são `mxrb find`, `mxrb describe` e `mxrb tree`.

## Avaliações de modelo

```ruby
result = Mxrb.open("app.mpr") do |project|
  project.evaluate do
    artifact "Sales.Order", kind: :entity
    no_call_cycles
    no_missing_internal_references
    maximum_unreferenced 20, severity: :warning
    forbid_dependency from: :Domain, to: :Presentation
  end
end

abort result.errors.map(&:message).join("\n") unless result.passed?
```

Arquivos de avaliação são Ruby comum e rodam com
`mxrb evaluate app.mpr evaluation.rb`; não existe linguagem de regras paralela.
