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

Como o Runtime, o servidor executa uma vez o microflow de after-startup das Model
Settings, sem usuário, antes dos scheduled events; se ele não retornar `true` ou
falhar (por exemplo, por uma Java action sem adapter), a aplicação não sobe.
`MXRB_AFTER_STARTUP=skip` sobe sem ele durante uma migração. O microflow de
before-shutdown roda ao fechar a aplicação, e suas falhas só são registradas.

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
entidade e direitos por member são verificados em cada requisição. As
constraints das access rules usam o mesmo motor XPath dos retrieves (associações,
funções e tokens entre aspas como `'[%CurrentUser%]'`); uma constraint que não
pode ser avaliada nega o acesso. Credenciais vêm de `MXRB_USERS_JSON` e `MXRB_AUTH_TOKENS`; use
arquivos locais ignorados pelo Git ou o secret manager do deployment.

Uma operação de published REST responde no caminho do serviço, do nome do recurso
e da operação. O microflow pode receber `System.HttpRequest` (URI, conteúdo,
versão e seus `System.HttpHeaders`) e `System.HttpResponse`, como no Runtime
Mendix 11.12.1 (`spec/fixtures/native_rest_http`, gravado com
`script/rest_native_oracle`). A resposta começa com o status de sucesso da
operação, e o status e os cabeçalhos que o microflow define são os da resposta
(vários `Set-Cookie` continuam separados). Um valor retornado é o corpo antes do
conteúdo da resposta: texto como está, o resto como JSON. A reason phrase é
ignorada.

Scheduled events usam o scheduler stdlib do MXRB, com intervalos de minuto,
hora e dia, prevenção de overlap e encerramento supervisionado. Falhas ficam
disponíveis no scheduler e não derrubam silenciosamente o servidor. Zonas IANA,
como `America/Boa_Vista`, usam `tzinfo`, inclusive nas transições de horário de
verão. Zonas desconhecidas geram erro em vez de cair silenciosamente para UTC;
`UTC`, `local` e offsets numéricos como `-04:00` também são aceitos.

Cada requisição roda no fuso da sessão: o `System.TimeZone` do usuário, quando
definido; senão a zona IANA que o navegador envia em `X-Mxrb-Time-Zone`; senão
UTC. O `/api/session` informa o fuso. Os objetos `System.TimeZone` do runtime são
criados na inicialização, e usuários novos recebem o fuso padrão do projeto, como
no Studio Pro.

Sessões e coordenação do scheduler usam por padrão o SQLite nativo compartilhado
`.mxrb/runtime/<ambiente>-shared.sqlite3`, sem serviço externo. Múltiplas
instâncias devem apontar `MXRB_SHARED_STORE_PATH` para o mesmo arquivo. Claims
idempotentes por evento/janela e leases de sobreposição renovados por heartbeat
são atômicos; um claim inacabado pode ser retomado após a expiração. O lease
padrão é de 300 segundos e pode ser alterado com `MXRB_SCHEDULER_LEASE_TTL`.
Use `:memory:`, `memory` ou `local` para ativar explicitamente o modo por processo.

Por padrão, Java Custom Actions não iniciam uma JVM. Cada ação permitida deve ter
um adapter Ruby explícito, registrado pelo nome qualificado em `config/adapters.rb`:

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
com seu nome e a instrução de registro; sem o sidecar opcional descrito adiante,
não há descoberta de classes, execução de JAR nem fallback para a JVM. REST, app services, SOAP, mappings e geração de
documentos continuam usando os adapters Ruby por tipo. O frontend permanece
JavaScript/React no navegador, servido pelo backend Ruby sem Runtime Java.

### Ações verificadas e contexto do microflow

Ações de módulos do Marketplace cujas fontes o MXRB auditou ganham adapters Ruby
prontos. A exportação compara o SHA-256 de cada ação, e das classes auxiliares que
ela chama, com as releases auditadas e grava os registros em
`config/verified_adapters.rb`. Esse arquivo é refeito a cada exportação e não é
embutido no MPR, então um round trip passa a usar ações auditadas depois. Ele é
carregado antes de `config/adapters.rb`; um registro neste arquivo substitui o
verificado de mesmo nome.

Do CommunityCommons há 19 ações auditadas nas releases 9.0.1 e 11.5.1, com as
diferenças entre elas: `Base64Encode`, `EndTransaction`, `GetApplicationUrl`,
`GetModelVersion`, `GetRuntimeVersion`, `Hash`, `RandomHash`, `RandomString`,
`RandomStrongPassword`, `StringFromFile`, `StringLeftPad`, `StringSplit`,
`StringTrim`, `ThrowException`, `TimeMeasureStart`, `TimeMeasureEnd`,
`copyAttributes`, `executeUnverifiedMicroflowAsUser_2` e `objectHasChanged`.
Do Encryption, `EncryptString` e `DecryptString` (releases 8.0.2 e 10.0.2) cifram
`{AES3}` com AES/GCM e decifram também o `{AES}` legado (AES/CBC), em formato
compatível com o Java; `{AES2}` falha como num Runtime 11.12.1 recém-iniciado, que
não tem o cipher `AES/GCM/PKCS5PADDING`. As ações PGP não têm adapter. No startup,
`UnitTesting.IsEnabled`, `Initialize`, `IsInitialized` e
`RegisterModelUpdateSubscriber` (10.0.4) seguem a constante `UnitTesting.Enabled`, e
`OIDC.DeleteExpiredAuthAttempts` (3.3.1) apaga as tentativas vencidas.
`MxModelReflection.SyncObjects` (6.2.0 e 8.0.2) porta o builder do módulo sobre o
metamodelo da aplicação, que reproduz o que o Runtime 11.12.1 informa
(`spec/fixtures/native_metamodel`). O módulo System é gravado por versão do Runtime
(10.24.0 e 11.12.1, que diferem em entidades de workflow, associações e valores de
enumeração), e cada projeto recebe a gravação mais recente que não seja mais nova que
a sua versão. `MXRB_ORACLE_MENDIX_VERSION` roda o fixture em outro Runtime, com o build
do mxrb quando aquele MxBuild não gera pacote portável, e `script/extract_system_metamodel`
guarda o módulo System dele.

Um adapter que precisa do microflow chamador usa `with_context: true` e recebe
`context:`, com o store, o log, outros microflows (também como outro usuário ou em
contexto sudo), o fim da transação, o estado de alteração de objetos, o conteúdo
de arquivos e a URL da aplicação (`MXRB_APPLICATION_ROOT_URL`, senão o endereço do
servidor Ruby). Exceções Java são `Mxrb::Runtime::JavaActionError` com o nome da
classe Java. Medido no Runtime 11.12.1 e reproduzido pelo app Ruby
(`spec/fixtures/native_java_action_runtime`):

- `$latestError/ErrorType` é o nome qualificado da classe Java e
  `$latestError/Message`, a mensagem da exceção;
- `isChanged` marca o objeto quando um membro é definido, mesmo com o valor que
  ele já tinha, até o próximo commit; um objeto novo sem valores definidos não
  está alterado;
- `IContext.endTransaction` confirma a transação, exceto dentro de um
  sub-microflow chamado com tratamento de erro customizado, cujo savepoint a
  mantém aberta; depois dele, cada commit é imediato;
- `Core.getModelVersion` é `unversioned` fora de uma implantação
  (`MXRB_MODEL_VERSION` define outro valor);
- com tratamento de erro customizado, uma chamada de sub-microflow que falha é
  desfeita até o savepoint (sem rollback) ou desfaz toda a transação (com
  rollback, `rescue_all(rollback: true)`), e o fluxo de erro continua, numa nova
  transação no segundo caso; uma Java action que falha mantém seus commits, e
  depois do fim da transação a chamada tratada roda numa transação própria
  (`spec/fixtures/native_error_handling_transactions`).

### Sidecar opcional para o Java do projeto

Os adapters Ruby ficam restritos aos módulos do Marketplace auditados acima. O
Java próprio do projeto, e o de módulos ainda não auditados, pode rodar no sidecar
de `docker/java-actions`, um processo Java separado (um container) que só é usado
quando `MXRB_JAVA_ACTIONS_URL` aponta para ele (`tcp://host:porta`). Sem essa
variável nada muda: a ação sem adapter falha fechado. A ordem de resolução é
adapter de `config/adapters.rb`, adapter verificado, ação da plataforma, sidecar e,
por fim, o erro.

O sidecar compila o `javasource` e o `userlib` do projeto contra uma API própria
com as partes de `com.mendix.*` que as ações usam. Não há jar da Mendix no sidecar.
A API cobre:

- `IContext`, `ISession`, `UserAction`/`CustomJavaAction`, `ILogNode` e
  `FeedbackHelper`; a mensagem vira o show-message do microflow chamador;
- `IMendixObject` e `IMendixIdentifier`, inclusive `getMembers`, os membros
  `MendixString`, `MendixInteger`, `MendixEnum`, `MendixObjectReference` etc.,
  `getState`, `isNew` e `getOriginalValue`, comparados com o último commit;
- os metadados (`IMetaObject`, `IMetaPrimitive`, `IMetaAssociation`,
  `IMetaEnumeration`, `IDataType`), vindos do metamodelo do app;
- em `Core`: os retrieves por XPath (`createXPathQuery`, `retrieveXPathQuery`,
  `retrieveXPathQueryAggregate`, `retrieveByPath`, `retrieveId`), `instantiate`,
  `commit`, `delete`, `rollback`, `microflowCall`, a configuração, as constantes,
  as versões (também `RuntimeVersion`), `getMetaObject(s)`, `getInputParameters`,
  `getReturnType`, `createDataType`, `getInternationalizedString` e o conteúdo de
  file documents (`getFileDocumentContent`, `storeFileDocumentContent`);
- OQL tabular (`retrieveOQLDataTable`, `createOQLTextGetRequest`,
  `createOQLTextGetRequestFromDataSet`, `IDataTable`, `IDataRow`, `IParameterMap`),
  executado pelo motor OQL do app Ruby; uma coluna de ID traz o identificador do
  objeto;
- request handlers: `Core.addRequestHandler` registra o caminho, e o servidor do
  app Ruby encaminha as requisições dele (fora de `/api`, sem token CSRF) ao
  `RequestHandler`, com `IMxRuntimeRequest`/`IMxRuntimeResponse` e a sessão do
  cookie `mxrb_session`; `Core.initializeGuestSession` abre uma sessão de convidado
  quando a segurança do projeto aceita convidados, e o id dela é o valor do cookie;
- `IMendixIdentifier.toLong` e `Core.createMendixIdentifier`, com o número guardado
  no banco do app; `Core.getDefaultLanguage`, `Core.initializeSession` (os
  microflows chamados com o contexto dela rodam como aquele usuário),
  `Core.executeAsync` (o sidecar roda o microflow antes de responder) e
  transações iniciadas pela ação, aninhadas na do microflow chamador.

Os proxies gerados também têm `load(context, xpath)`, como os do Studio Pro. O
`org.json` que a Mendix embute como `com.mendix.thirdparty.org.json` (`JSONObject`,
`JSONArray`, `JSONException`) tem implementação própria no sidecar, e
`IContext.getRuntimeRequest`/`getRuntimeResponse` ficam vazios, porque o app Ruby
não repassa a requisição HTTP às ações.

Trabalho que uma ação deixa rodando depois de retornar, como um listener de
mensagens MQTT que chama um microflow, também passa pelo app Ruby: ao iniciar o
runtime, ele abre uma conexão de escuta com o sidecar, e a cada callback desse
trabalho o sidecar pede por ela uma conexão própria, atendida numa transação nova
com contexto de sistema. A conexão parte sempre do app Ruby, que não precisa
aceitar conexões do container. Isso vale também para o contexto que a ação guarda
para depois, como faz o listener do MqttConnector. Os objetos que um callback
devolve valem só nele, e um objeto de uma invocação encerrada não pode ser
repassado.

Também há agregados em `XPathQuery` (`executeAggregateLong`/`Double`, com as
variáveis da consulta; valores vazios ficam de fora, como no SQL), `Core.authenticate`,
`Core.getLanguage`, o administrador do projeto em `Configuration`, e
`Core.metrics()` e assinantes de log, que existem mas não registram nada, porque
o log e as métricas ficam no app Ruby. Tipos internos do Runtime que só são
importados (`ICore`, `DataStorage`, `Http`, `Integration`) existem vazios; o
código que os usa não compila.

Uma fonte que usa outra API não compila e fica de fora, com o primeiro erro
registrado em `build-report.tsv`; chamar essa ação gera um erro que cita esse
motivo. As legendas de enumeração seguem as traduções do app Ruby; os proxies que o
Studio Pro gera usam o id do texto de cada legenda, e o pacote grava a relação entre
esses ids e os valores em `captions.tsv`.

O app Ruby continua sendo o Runtime. Cada chamada abre uma conexão com mensagens
JSON por linha. O Java recebe handles dos objetos do microflow e lê, altera, faz
commit, consulta e chama microflows por callbacks, então a transação, os eventos,
o acesso a entidades e o log ficam no Ruby. Um microflow chamado pelo Java pode
chamar outra Java action, que roda numa conexão própria. Atributos Integer chegam
como `java.lang.Integer`, reference sets vazios como lista vazia, e a exceção que a
ação lança vira `$latestError` com a classe Java. `MXRB_JAVA_ACTIONS_TOKEN`, se
definido nos dois lados, autentica as chamadas; `MXRB_JAVA_ACTIONS_TIMEOUT`
(300 s por padrão) limita a espera por cada mensagem. O caso
`spec/fixtures/java_action_sidecar` compila e roda ações reais contra o app Ruby.

`mxrb java-actions App.mpr app-ruby` prepara o sidecar de um app exportado, sem
mudar a exportação, que continua sem nenhum arquivo Java. O comando grava em
`java-actions/` o Dockerfile e as fontes do sidecar, uma cópia do `javasource` do
projeto (fontes que não são UTF-8 são lidas como ISO-8859-1) com os proxies que o
Studio Pro geraria e não são versionados, e os jars do `userlib` e do `vendorlib`. Também cria um
`docker-compose.yml`, se ainda não existir, com o serviço `java-actions` em
`127.0.0.1:7911`. O diretório é refeito a cada execução e não é embutido no MPR:

```sh
mxrb java-actions App.mpr app-ruby
cd app-ruby && docker compose up -d java-actions
```

Defina a URL no perfil de ambiente do app:

```sh
# config/environments/development.env
MXRB_JAVA_ACTIONS_URL=tcp://127.0.0.1:7911
```

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
