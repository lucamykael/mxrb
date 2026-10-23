# Microflows e nanoflows organizados por métodos

A exportação usa `main_line` para mostrar a sequência principal, métodos nomeados
para as atividades e referências de métodos nas decisões e nos loops. Parâmetros,
tipo de retorno, documentação, permissões e opções ficam em `flow_contract`.

Antes, a lógica inteira precisava aparecer dentro de blocos aninhados:

```ruby
flow :microflow do
  parameter :Approved, type: :Boolean
  parameter :Order, type: object_of('Sales.Order')
  return_type :Integer
  create_variable :Result, type: :Integer, value: '0'
  decision '$Approved' do
    on true do
      change_variable :Result, to: '10'
    end
    on false do
      change_variable :Result, to: '20'
    end
  end
  commit :Order
  return_value '$Result'
end
```

O formato novo permite ler a orquestração sem entrar nos detalhes de cada card:

```ruby
class ProcessOrder < Mxrb::RubyApp::Service
  mendix_name 'Sales.ProcessOrder'

  def main_line
    initialize_total
    decide '$Approved', branches: { true => :approve_order, false => :reject_order }
    commit_order
    return_value '$Result'
  end

  private

  def flow_contract
    parameter :Approved, type: :Boolean
    parameter :Order, type: object_of('Sales.Order')
    return_type :Integer
  end

  def initialize_total
    create_variable :Result, type: :Integer, value: '0'
  end

  def approve_order
    change_variable :Result, to: '10'
  end

  def reject_order
    change_variable :Result, to: '20'
  end

  def commit_order
    commit :Order
  end

  flow :microflow, main: :main_line
end
```

`commit_order` é a continuação comum depois da decisão; o compilador materializa
o merge no grafo. Métodos usam captions úteis do Studio Pro. Captions genéricas
usam o nome da operação e seu alvo. Identificadores são normalizados e colisões
recebem sufixos determinísticos, sem alterar a identidade dos elementos nativos.
Uma ramificação de uma única atividade referencia diretamente esse método,
evitando um método adicional que só chamaria outro.

## Loops, chamadas, retornos antecipados e erros

Loops e handlers recebem um `Proc` que vincula o método ao contexto correto do
builder. Ramos vazios e saídas curtas podem usar lambdas, sem métodos artificiais:

```ruby
def main_line
  initialize_total
  decide '$Skip', branches: { true => -> { return_value '-1' }, false => -> {} }
  loop_over :Orders, as: :Order, &step(:process_order)
  call_microflow 'Sales.Summarize', as: :Summary, pass: { 'Sales.Summarize.Total' => '$Total' }
  rescue_all rollback: true, &step(:handle_failure)
  return_value '$Summary'
end

def process_order
  validate_order
  decide '$Ignore', branches: { true => -> { continue_loop }, false => :add_order }
end

def handle_failure
  return_value '-2'
end
```

`step(:method_name)`, `step(method(:method_name))` e `step { ... }` aceitam métodos
e blocos pequenos. `decide` também aceita `Proc` nas suas ramificações. Um
`break_loop` continua permitido somente dentro de um loop, inclusive quando está
em um método separado. Decisões por regra e por herança preservam seus argumentos,
tipos e ramo padrão em métodos auxiliares próprios.

Os métodos **compõem a definição tipada** quando o projeto Ruby é carregado.
`'$Approved'` continua sendo uma expressão Mendix; não é uma condição `if` de Ruby.
Na execução, `Service#call` usa o runtime Ruby do MXRB para avaliar as expressões e
percorrer o grafo. O formato não usa `if '$Approved'`, que seria sempre verdadeiro
em Ruby. `return_value`/`end_flow` declaram saídas do microflow; `return` de Ruby
apenas sai do método que está compondo a definição.

O método principal é autoritativo: editar uma atividade, reordenar suas chamadas,
mudar uma ramificação ou remover um método de sua sequência altera a definição
compilada. Os métodos não são comentários ou uma segunda representação decorativa.

## Exportação e compatibilidade

O modo Ruby exporta serviços como o exemplo acima. O modo Mendix usa a mesma API
de métodos em uma classe anônima, sem constantes globais que possam colidir entre
módulos ou arquivos:

```ruby
microflow :ProcessOrder, plan: Class.new(Mxrb::Dsl::FlowProgram) {
  def main_line
    create_variable :Result, type: :Integer, value: '1'
    return_value '$Result'
  end
}
```

`nanoflow` e `rule` também aceitam `plan:`. Serviços aceitam
`flow :microflow, main: :main_line`, `flow :nanoflow, main: :main_line` e
`flow :rule, main: :main_line`. As declarações antigas com `do ... end` e o alias
`native` continuam funcionando. Um mesmo fluxo não pode usar `plan:`/`main:` e
bloco de definição simultaneamente.

Metadados de IDs, layout e referências continuam nos sidecars existentes. O teste
de ida e volta verifica igualdade dos documentos nativos sem edições; depois de
editar o corpo, verifica o novo resultado executado e a preservação dos IDs das
unidades. A forma de organizar os métodos não amplia os tipos de grafos e ações
que o exportador consegue interpretar. Formas sem mapeamento tipado continuam com
o diagnóstico e as limitações anteriores; não são reescritas como um fluxo linear.

Fontes Ruby incorporadas pelo usuário continuam sendo preservadas. Para obter o
novo estilo a partir de um modelo existente, exporte para um diretório novo e
revise o resultado; esta mudança não sobrescreve projetos Ruby já vinculados.

As provas estão em `spec/method_flow_source_spec.rb`, incluindo execução,
decisão/merge, retorno antecipado, chamadas, loops com break/continue,
erro/rollback, captions, Unicode, callbacks concorrentes e ambos os modos de
exportação. Os oráculos em `spec/runtime/microflow_oracles_spec.rb` continuam
verificando os comportamentos registrados no runtime Mendix.
