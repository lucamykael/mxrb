# Certificar edições Ruby em projetos reais

`script/certify_presentation_edits` exporta fixtures fixadas, remove a cópia de
runtime do MPR e compila primeiro sem edições. Depois aplica as substituições
Ruby declaradas no plano e compara a reconstrução com uma cópia esperada editada
diretamente nos campos nativos. A comparação integral detecta mudanças extras;
uma inspeção direta também confirma os valores esperados nos documentos.

O [plano versionado](../../spec/fixtures/presentation_edits/cases.json) fixa
revisões e checksums de três projetos:

| Pasta sob a raiz das fixtures | Repositório | Revisão |
|---|---|---|
| `connector` | `ako/ConnectorKitDemo` | `9eed61f1fb737d189a3b018ac7691c87569053de` |
| `mendix9` | `bhataparnak/MendixApp` | `8912322e170e5babb4bf77461242ae51b555ca42` |
| `sudoku` | `ako/mxcli-sudoku` | `918af72e43ca8e1d61fb0c32ad13d8da94b944e2` |

```sh
bundle exec ruby script/certify_presentation_edits \
  --plan spec/fixtures/presentation_edits/cases.json \
  --fixtures /tmp/fixtures --output /tmp/presentation-edits
```

`--label mendix7`, `mendix9` ou `mendix11` seleciona uma família. A saída deve
ser nova e externa aos projetos-fonte. Labels duplicados, checksums divergentes,
substituições ambíguas e caminhos/symlinks que saem do workspace são recusados.
Os arquivos `edits.json` e `cases.json` registram os resultados; apenas casos
estruturais aprovados entram no segundo arquivo.

## Escopo das edições

- Mendix 7: título da página, classe do layout e texto do snippet pelo Ruby
  público. `Widget` singular e seus contêineres internos são projetados;
  campos de widgets legados sem equivalente no catálogo Forms 11 ficam
  preservados em declarações `native_widget` inline.
- Mendix 9: título da página, classe do layout e texto parametrizado do snippet
  pelas declarações públicas Ruby.
- Mendix 11: título visível da página Sudoku, classe do layout e texto do snippet
  pelas declarações públicas Ruby, preservando os dois idiomas do snippet.

As cópias retêm `theme-cache` quando ele integra a origem, pois o comparador
inclui esses assets. Os originais permanecem inalterados.

## Oráculo nativo e navegador

`cases.json` é compatível com `script/mxbuild_oracle`. O workflow legado prepara
as edições das famílias 7, 9 e 11 e executa seus MxBuild no Windows. Um resultado
`equivalent` continua sendo uma comparação de falhas iguais. Todos os onze casos
do workflow usam `--require-build`, que retorna falha para `equivalent`.
Isso inclui os projetos legados 5.21.4, 6.10.8, 7.5.0, 7.17.0 e 9.6.1,
além das três edições de apresentação e três casos de propriedades escalares.
O plano `property_cases.json` verifica 33 alterações públicas Ruby nas versões
7/9/11; o [relatório de editabilidade](../planning/ruby-editability.pt-BR.md)
separa esse escopo das operações ainda não suportadas. O 5.21.4 usa sua ferramenta exata no
Windows; o QueryApiBlogPost restaura 16 dependências Maven declaradas,
fixadas em `spec/fixtures/presentation_edits/query-api-dependencies.json`.
Um pacote vazio também falha; tamanho e SHA-256 do pacote entram no relatório.
Uma aprovação estrutural local registra `native_oracle: not_run` até existir
evidência nativa separada.

No Mendix 11, o gate usa MxBuild 11.12.1 e JDK 21 para gerar ambos os pacotes.
`mx check` nas cópias `source` e `rebuilt` também verifica o modelo localmente.
Para a verificação visual, compile o frontend em `mendix11/ruby/frontend` com
`npm ci && npm run build` e execute o cenário
[`presentation_edits_sudoku_flow.json`](../../spec/fixtures/frontend_browser/presentation_edits_sudoku_flow.json)
com `script/browser_fixture_gate`, que inicia e encerra o servidor:

```sh
bundle exec ruby script/browser_fixture_gate --kind app \
  --source /tmp/presentation-edits/mendix11/ruby \
  --scenario spec/fixtures/frontend_browser/presentation_edits_sudoku_flow.json \
  --output tmp/presentation-behavior
```

Ele confere apresentação, recarga e 43 passos de gameplay: três níveis, seleção,
dica, desfazer, notas e retorno. O cenário `presentation_persistence_flow.json`
usa uma exportação nova de `spec/fixtures/persistent_page_drafts/project.rb`,
com `MXRB_DATAGRID_PACKAGE` apontando para o Datagrid da fixture Sudoku. Gere
e exporte para diretórios novos, compile o frontend e execute o mesmo gate.
Não reutilize um banco de uma execução anterior: o cenário exige zero linhas
antes de salvar, uma após recarga, mensagem `Name is required` para nome vazio
e nenhuma gravação inválida. Relatórios e capturas ficam no diretório `--output`.

A [evidência da continuação](../evidence/backlog-2026-11-18.json) separa
comparação estrutural, pacotes nativos, check e navegador, com links para os
runs e hashes dos relatórios.

## Bibliotecas do Mendix 7

Antes de preparar as cópias do oráculo, execute:

```sh
bundle exec ruby script/prepare_oracle_dependencies \
  spec/fixtures/presentation_edits/connector-dependencies.json \
  /tmp/fixtures/connector/userlib
```

O manifesto deriva das versões `testRuntime` do `build.gradle` fixado e inclui
as transitivas resolvidas. Cada download é conferido por SHA-256; um arquivo
existente com hash diferente é recusado. As mesmas bibliotecas entram na origem
e na reconstrução. Os 87 fontes Java passaram em `javac` 8 com essas bibliotecas
e as APIs 7.5. MxBuild 7.5 no Windows também gerou ambos os pacotes.

## Recursos do Mendix 9

A fixture original omite pacotes e arquivos de inicialização do Atlas.
O manifesto `mendix9-assets.json` fixa Atlas Core 3.0.7, Atlas Web Content 3.0.6,
AnyChart 3.0.2 e Data Widgets 2.0.1 com URLs oficiais e SHA-256. O workflow
extrai apenas `themesource/` e `widgets/`, preservando todas as units do MPR.

Os arquivos em `mendix9-theme/web/` restauram a configuração Atlas 3, a
compilação Sass e a importação das variáveis padrão que Data Widgets usa.
`theme/web/settings.json` habilita a interpretação flexível das colunas;
os pesos `-1` da fixture permanecem intactos. Os widgets contemporâneos ao
Mendix 9.6 correspondem às definições armazenadas. Não é necessário atualizar
widgets no modelo nem remover páginas, layouts ou snippets.
