# Runtime sem Java

O modo Ruby executa o backend sem iniciar o Mendix Runtime Java. Ao abrir uma
aplicação exportada, o MXRB migra automaticamente um banco SQLite por ambiente,
abre o interpretador de microflows, registra lifecycle hooks, aplica segurança e
inicia os scheduled events.

```text
config/environments/
├── development.env
├── qa.env
├── staging.env
└── production.env
```

A precedência é `ENV do processo > config/environments/<ambiente>.env >
.env.<ambiente> > .env`. Selecione o perfil com `--environment qa` ou
`MXRB_ENV=qa`. `mxrb env . --environment qa` lista somente nomes de chaves e
fontes; valores nunca são impressos.

```bash
mxrb run . --environment qa
mxrb test App.mpr smoke.rb --native --environment qa
```

Cada perfil usa, por padrão, `.mxrb/runtime/<ambiente>.sqlite3`. O schema deriva
de entidades, atributos, associações e system members; mudanças aditivas são
aplicadas de forma idempotente e mudanças incompatíveis usam rebuild
transacional. Entidades não persistentes continuam somente em memória.

A API Ruby oferece login e tokens bearer, sessão, schema, navigation, pages,
microflows, CRUD e published REST. Regras de página/microflow, access rules de
entidade, direitos por member e o subconjunto seguro de XPath são verificados em
cada requisição. Credenciais vêm de `MXRB_USERS_JSON` e `MXRB_AUTH_TOKENS`; use
arquivos locais ignorados pelo Git ou o secret manager do deployment.

Scheduled events usam o scheduler stdlib do MXRB, com intervalos de minuto,
hora e dia, prevenção de overlap e encerramento supervisionado. Falhas ficam
disponíveis no scheduler e não derrubam silenciosamente o servidor. Zonas IANA,
como `America/Boa_Vista`, usam `tzinfo`, inclusive nas transições de horário de
verão. Zonas desconhecidas geram erro em vez de cair silenciosamente para UTC;
`UTC`, `local` e offsets numéricos como `-04:00` também são aceitos.

Sessões e coordenação do scheduler usam por padrão o SQLite nativo compartilhado
`.mxrb/runtime/<ambiente>-shared.sqlite3`, sem serviço externo. Múltiplas
instâncias devem apontar `MXRB_SHARED_STORE_PATH` para o mesmo arquivo. Claims
idempotentes por evento/janela e leases de sobreposição renovados por heartbeat
são atômicos; um claim inacabado pode ser retomado após a expiração. O lease
padrão é de 300 segundos e pode ser alterado com `MXRB_SCHEDULER_LEASE_TTL`.
Use `:memory:`, `memory` ou `local` para ativar explicitamente o modo por processo.

Java Custom Actions não iniciam uma JVM. Cada ação permitida deve ter um adapter
Ruby explícito, registrado pelo nome qualificado em `config/adapters.rb`:

```ruby
Mxrb::RubyApp::Registry.register_java_custom_action('Pedidos.CalcularTotal') do |arguments|
  Calculador.call(
    itens: arguments.fetch('Itens'),
    desconto: arguments.fetch('Desconto')
  )
end
```

As chaves são os nomes dos parâmetros no modelo Mendix. Valores básicos são
avaliados no contexto do microflow; referências de entidade, microflow e
mappings são entregues como nomes qualificados. O retorno alimenta a variável
de resultado apenas quando `UseReturnVariable` está ativo (ou no formato legado
que declara somente `ResultVariableName`). Uma ação sem registro falha fechado
com seu nome e a instrução de registro; não há descoberta de classes, execução
de JAR nem fallback para a JVM. REST, app services, SOAP, mappings e geração de
documentos continuam usando os adapters Ruby por tipo. O frontend permanece
JavaScript/React no navegador, servido pelo backend Ruby sem Runtime Java.

## Certificação Ruby → Mendix → Ruby

O cenário reproduzível de certificação fica em
[`spec/fixtures/flymetothemoon/project.rb`](../../spec/fixtures/flymetothemoon/project.rb).
Ele modela em Ruby clientes, produtos, pedidos e itens, incluindo enumeração,
índices, associações, microflows, nanoflow, scheduled event e uma página com
data grid. O teste
[`spec/flymetothemoon_roundtrip_spec.rb`](../../spec/flymetothemoon_roundtrip_spec.rb)
verifica estes casos de uso:

- gerar e validar um MPR Mendix 11.12.1 a partir da DSL Ruby;
- exportar pelo CLI real com `--mode ruby --flymetothemoon`;
- garantir que o preset contenha Sinatra, Puma, ActiveRecord e RSpec, sem
  arquivos Java, JAR ou bytecode;
- executar criação, contagem, decisão, CRUD e metadados de página no Runtime
  Ruby com SQLite;
- recompilar sem alterações e comparar o MPR estruturalmente com a origem;
- adicionar um atributo e substituir um microflow por Ruby idiomático;
- exportar novamente e provar que código Ruby e modelo Mendix sobrevivem a um
  segundo round-trip estruturalmente idêntico.

Execute o caso isolado com:

```bash
bundle exec rspec spec/flymetothemoon_roundtrip_spec.rb
```

Para interfaces geradas, o cenário declarativo
[`spec/fixtures/frontend_browser/sudoku_full_flow.json`](../../spec/fixtures/frontend_browser/sudoku_full_flow.json)
é executado pelo runner `script/frontend_browser_acceptance` em Chromium real.
Ele cobre as posições 73 e 74 do tabuleiro, seleção, preenchimento e troca entre
Easy, Medium e Hard. Cada clique crítico aguarda a cadeia POST do microflow + GET
da associação e deve concluir em até 250 ms. A consulta da galeria é filtrada no
SQLite pelo contexto; objetos carregados pela associação inversa preservam o
vínculo quando somente atributos são salvos.
