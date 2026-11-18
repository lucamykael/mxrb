# Editabilidade após converter MPR para Ruby

Auditoria iniciada em 18/11/2026. Escopo inicial: páginas, layouts e snippets
exportados com `--mode ruby`. A preservação de um documento e a geração de um
pacote executável não demonstram, sozinhas, que suas propriedades podem ser
alteradas pelo código Ruby da aplicação.

## Critério de aceite

Cada operação precisa demonstrar, separadamente:

1. Qual declaração pública Ruby representa o campo original.
2. Qual edição foi aplicada nessa declaração, sem editar o sidecar ou a baseline.
3. Que o MPR reconstruído contém exatamente a edição nativa esperada, comparando
   todas as units e preservando campos e identidades não relacionados.
4. Que uma segunda exportação e reconstrução mantém a edição.
5. Que o MxBuild da versão do projeto gera um pacote quando o cenário é nativo.
6. Que o comportamento observável funciona no runtime correspondente quando
   a alteração afeta interação ou persistência.

O relatório `portability` descreve a materialização em Mendix; seu status
`native` não deve ser interpretado como cobertura de todas as operações de
edição Ruby. Uma operação não testada permanece não certificada. O JSON de `portability`
agora inclui `ruby_page_editing`, com as opções escalares e as limitações
explícitas desse contrato, sem convertê-las em alegação de certificação.

## Achados reproduzidos

- **Estilo de botão e hierarquia de texto:** o Sudoku exportava `button_style`
  e `render_mode`, mas a reconstrução recusava mudanças nesses campos. Os dois
  ensaios reais anteriores à correção falharam com `PageEdits::UnsupportedEdit`.
- **Propriedades de inputs e DataViews:** a apresentação Ruby expunha opções
  que `PageEdits` não transferia para o documento. O primeiro lote acrescenta
  sincronização explícita de escalares, sem reconstruir o widget inteiro.
- **Contrato da página:** parâmetros, variáveis, popup, autofocus e `excluded`
  não participavam da comparação das páginas Ruby. Agora uma alteração não
  suportada nesses valores interrompe a compilação, em vez de desaparecer.
- **Diferença entre versões:** DataView usa `Editable: true/false` nas fixtures
  Mendix 7/9 e `Editability: Always/Never` no Mendix 11. A correção preserva o
  campo original; `conditional` não é aceito na representação booleana.

## Primeiro lote de operações

O plano [property_cases.json](../../spec/fixtures/presentation_edits/property_cases.json)
fixa três projetos públicos e 33 alterações em campos existentes:

| Projeto | Versão | Alterações |
|---|---|---:|
| ConnectorKitDemo | 7.5.0 | 10 |
| FirstMedix App | 9.6.1 | 10 |
| Sudoku | 11.12.1 | 13 |

As operações cobrem `editable`, `read_only_style`, `password`, `max_length`,
`tab_index`, `label_width`, `show_footer`, `aria_required`, `button_style` e
`render_mode`. A suíte isolada também verifica `render_type`, uma segunda
exportação, rejeição de valores inválidos, campos inexistentes, tipos nativos
incompatíveis e divergência da baseline. Também permite definir `render_type`
e `render_mode` quando seus valores padrão foram omitidos da declaração exportada. Campos não presentes na versão de
origem continuam sendo recusados; nenhum default de outra versão é introduzido.

```sh
bundle exec ruby script/certify_presentation_edits \
  --plan spec/fixtures/presentation_edits/property_cases.json \
  --fixtures local-projects/matrix --output /tmp/property-edits
bundle exec rspec spec/ruby_page_property_edits_spec.rb
```

O diretório de saída deve ser novo. A raiz das fixtures deve conter
`ConnectorKitDemo`, `MendixApp` e `mxcli-sudoku`, nas revisões/checksums do plano.
A certificação remove a cópia de runtime do MPR antes de compilar. A fixture
original permanece intacta. `edits.json` registra cada valor anterior e novo;
`cases.json` encaminha somente casos aprovados ao oráculo nativo.

O workflow `Legacy MxBuild oracle` inclui três casos adicionais para essas
propriedades e exige `--require-build`. Comparação estrutural e aprovação
nativa têm resultados separados. O cenário
`page_property_edits_flow.json` verifica em 44 passos o título `h2`, o estilo
do botão, recarga e gameplay no Chromium, sem erros de console. A cobertura sintética de uma propriedade
não certifica automaticamente todas as versões, widgets ou combinações.

### Reprovação nativa que a comparação estrutural não detectou

No [primeiro ensaio nativo](https://github.com/lucamykael/mxrb/actions/runs/44364326890),
os três casos de propriedades foram reprovados: ocultar o rodapé externo de
`Administration.Account_New` deixava botões incompatíveis com a regra do Mendix
para rodapés ocultos. O MPR correspondia exatamente à edição solicitada, mas essa
edição não formava uma página válida. O plano passou a mostrar o rodapé interno,
originalmente vazio, mantendo os botões externos. A reprovação fica registrada
como evidência de que comparação integral não substitui compilação nativa;
`PageEdits` não implementa todas as regras de consistência do Studio Pro.

## Backlog de editabilidade

| ID | Prioridade | Operação | Situação e prova necessária |
|---|---|---|---|
| EDIT-001 | P0 | Detectar alterações de contrato de página ignoradas | Implementado: alterações não suportadas em parâmetros, variáveis, popup, autofocus e exclusão falham explicitamente. |
| EDIT-002 | P1 | Sincronizar propriedades escalares já exportadas | 33 campos reais aprovados na comparação integral; 15 ensaios isolados também cobrem reexportação. A certificação nativa é registrada separadamente. |
| EDIT-003 | P1 | Alterar bindings, fontes de dados e ações de widgets | `PageEdits` ainda recusa essas mudanças; exigir edição isolada, execução da ação e comparação integral. |
| EDIT-004 | P1 | Adicionar, mover e renomear widgets em páginas existentes | A inclusão é recusada; remoção/reordenação têm suporte limitado à estrutura que o sincronizador encontra. Exigir testes de parent, listas e campos singulares, identidades e referências. |
| EDIT-005 | P1 | Editar parâmetros, variáveis, popup e acesso à página | Atualmente recusado na projeção da aplicação; implementar transformação nativa por versão e cenários de chamada/acesso. |
| EDIT-006 | P1 | Criar/remover layouts e snippets; mudar seus parâmetros | `PresentationEdits` recusa essas operações. Exigir atualização de chamadas e referências, além do documento. |
| EDIT-007 | P1 | Editar propriedades e eventos de widgets Marketplace | Validar por pacote e schema fixados; exibir a distinção entre declaração pública, preservação e comportamento realmente testado. |
| EDIT-008 | P2 | Editar placeholder, acessibilidade, traduções e textos parametrizados | Ainda faltam operações completas, incluindo textos inicialmente vazios e preservação de idiomas/parâmetros. |
| EDIT-009 | P1 | Inventário do projeto de uso real | Auditar também domínio, associações, regras, microflows/nanoflows, navegação e integrações. Esses grupos não foram certificados por esta auditoria de apresentação. |

Nenhum item pendente desta tabela é contado como concluído por um round-trip
sem edição. As próximas operações devem ganhar casos que falhem antes da
correção e comparem o resultado com uma expectativa nativa independente.
