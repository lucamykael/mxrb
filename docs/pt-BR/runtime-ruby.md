# Runtime sem Java

## Modbus TCP e RTU

`Mxrb::Modbus::Client` é um conector próprio para o backend Ruby. Implementa
as funções 01/02/03/04/05/06/15/16 da
[especificação Modbus](https://www.modbus.org/modbus-specifications).
Não é um pacote oficial Marketplace nem gera uma implementação Java para Mendix.
O mesmo cliente aceita `transport: :tcp` (padrão) ou `transport: :rtu`.
TLS e conversões de registradores para floats não fazem parte desta API.

```ruby
client = Mxrb::Modbus::Client.new(host: ENV.fetch('MODBUS_HOST'), unit_id: 1, timeout: 5)
client.read_holding_registers(0, 2)       # => [4660, 65535]
client.read_coils(0, 8)                  # => Array de true/false
client.write_single_register(10, 42)     # => 42
client.write_multiple_coils(0, [true, false]) # => 2
```

Também estão disponíveis `read_discrete_inputs`, `read_input_registers`,
`write_single_coil` e `write_multiple_registers`. Endereços começam em zero:
o registrador convencional 40001 corresponde ao endereço 0 de holding registers.
Registradores usam inteiros sem sinal de 0 a 65535; coils exigem booleanos.
Leituras retornam arrays, escritas simples retornam o valor e escritas múltiplas
retornam a quantidade confirmada. A porta padrão é 502 e `unit_id` aceita 0–255
para endereçar também gateways.

No TCP, cada operação abre e fecha sua conexão, com um prazo total em segundos para
resolução/conexão, envio e resposta. Não há repetição automática: um timeout após
uma escrita deixa o resultado remoto desconhecido. `ExceptionResponse` expõe
`function` e `code`; `ProtocolError` indica resposta inválida e `TransportError`
(incluindo `TimeoutError`) indica falha de comunicação. Modbus TCP não oferece
autenticação ou criptografia; configure o endpoint pela aplicação em rede confiável.

Um adapter em `config/adapters.rb` pode retornar
`client.read_holding_registers(0).first` para uma ação registrada com
`Registry.register_java_custom_action('Industrial.ReadRegister')`. O microflow
consome esse valor pelo interpretador Ruby; o adapter não é exportado como Java.

### Simulação local por TCP

Execute `bundle exec ruby examples/modbus_tcp_simulator.rb` na raiz do MXRB.
O simulador escuta somente em `127.0.0.1:1502`, com `unit_id: 1` e endereços
0–255 em cada área. Um argumento numérico altera a porta. Coils e holding
registers começam zerados e preservam escritas até o processo encerrar; a
entrada discreta 0 começa em `true` e o input register 0 em `1234`.

Em outro processo Ruby, depois de `require 'mxrb'`:

```ruby
client = Mxrb::Modbus::Client.new(transport: :tcp, host: '127.0.0.1', port: 1502)
client.write_multiple_registers(0, [42, 123])
p client.read_holding_registers(0, 2) # [42, 123]
```

O simulador é uma ferramenta de desenvolvimento, com estado apenas em memória.
Use Ctrl+C para encerrá-lo.

Para exercitar a aplicação completa, execute
`bundle exec ruby examples/modbus_application.rb`. O exemplo inicia seu próprio
simulador em uma porta livre, gera e valida um MPR com a entidade `Measurement`
e o microflow `Industrial.ConfigureAndSample`, escreve os setpoints 42 e 84 e
salva as leituras em SQLite. Depois reabre o banco e verifica as duas medições.
O resultado JSON informa os caminhos do MPR e do banco, preservados em um diretório
temporário para inspeção. O simulador é encerrado automaticamente.

### Porta serial RTU

O RTU recebe um IO serial já aberto e configurado pela aplicação/sistema em
modo raw, 8E1, 8O1 ou 8N2, sem eco local. O adaptador deve controlar a direção
RS-485. `baud_rate` informa a velocidade configurada para calcular os intervalos;
ele não altera os parâmetros da porta. Não há dependência de uma biblioteca
serial específica. Exemplo POSIX para uma porta previamente configurada:

```ruby
File.open('/dev/ttyUSB0', File::RDWR | File::NONBLOCK | File::NOCTTY) do |serial|
  client = Mxrb::Modbus::Client.new(transport: :rtu, io: serial, baud_rate: 9600, unit_id: 1)
  p client.read_holding_registers(0, 2)
end
```

RTU exige `unit_id` entre 1 e 247; broadcast não é suportado. Use um único cliente
por barramento; chamadas simultâneas são recusadas até a validação completa da
resposta terminar. A aplicação continua responsável por fechar o IO. CRC, tamanho,
endereço e função são verificados, com separação entre quadros e limite entre
caracteres observados pelo software. Erros de transporte/protocolo invalidam a
sessão: reabra e ressincronize a porta antes de criar outro cliente; não repita
automaticamente uma escrita de resultado desconhecido. Uma exceção válida do
dispositivo não invalida a sessão. Testes usam pseudo-terminal e TCP local;
temporização elétrica, drivers USB e equipamento físico ainda precisam de validação.

## Execução do backend

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

Durante `mxrb run`, o backend interpreta os arquivos Ruby e verifica mudanças
no início de cada requisição; o frontend continua com o HMR do Vite. Um reload
bem-sucedido troca o registro da aplicação e o runtime sob um único lock. Se o
código novo tiver erro de sintaxe, declaração inválida ou migração insegura, a
última versão válida continua atendendo e `/api/health` expõe o erro de reload.
Use `--no-reload` quando precisar fixar o processo em uma única revisão.

Esse ciclo de desenvolvimento não escreve o `.mpr` e não executa MxBuild. O
`.mpr` só é sincronizado no limite explícito de `mxrb export`; até lá, páginas,
serviços e modelos Ruby são executados pelo backend, enquanto artefatos nativos
que ainda não têm implementação Ruby continuam no interpretador a partir do
snapshot Mendix exportado.

Cada perfil usa, por padrão, `.mxrb/runtime/<ambiente>.sqlite3`. Em `mxrb run`,
o schema deriva das classes Ruby atuais, sobreposto ao snapshot nativo para os
artefatos restantes. Entidades, atributos, associações e system members novos
são aplicados de forma incremental. Mudanças aditivas são
aplicadas de forma idempotente e mudanças incompatíveis usam rebuild
transacional. Remoções destrutivas falham fechado, a menos que
`MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=true` esteja configurado. Entidades não
persistentes continuam somente em memória.

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
