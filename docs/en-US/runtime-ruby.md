# Java-free runtime

## Modbus TCP and RTU

`Mxrb::Modbus::Client` is MXRB's own Ruby backend connector for functions
01/02/03/04/05/06/15/16 of the
[Modbus specification](https://www.modbus.org/modbus-specifications).
It is not an official Marketplace package and does not generate Mendix Java code.
The same client accepts `transport: :tcp` (default) or `transport: :rtu`.
TLS and register-to-float conversions are outside this API.

```ruby
client = Mxrb::Modbus::Client.new(host: ENV.fetch('MODBUS_HOST'), unit_id: 1, timeout: 5)
client.read_holding_registers(0, 2)       # => [4660, 65535]
client.read_coils(0, 8)                  # => Array of true/false
client.write_single_register(10, 42)     # => 42
client.write_multiple_coils(0, [true, false]) # => 2
```

The remaining methods are `read_discrete_inputs`, `read_input_registers`,
`write_single_coil` and `write_multiple_registers`. Addresses are zero-based:
conventional holding register 40001 maps to address 0. Registers are unsigned
integers from 0 to 65535; coils require booleans. Reads return arrays, single
writes return the value, and multiple writes return the acknowledged quantity.
The default port is 502; `unit_id` accepts 0–255, including gateway addressing.

For TCP, each operation opens and closes its connection with one total deadline in seconds
for resolution/connection, sending and receiving. There are no automatic retries:
a write timeout leaves the remote outcome unknown. `ExceptionResponse` exposes
`function` and `code`; `ProtocolError` indicates an invalid response, and
`TransportError` (including `TimeoutError`) indicates a communication failure.
Modbus TCP has no authentication or encryption; configure the endpoint in the
application on a trusted network.

In `config/adapters.rb`, an adapter registered through
`Registry.register_java_custom_action('Industrial.ReadRegister')` can return
`client.read_holding_registers(0).first`. The Ruby microflow interpreter consumes
the result; the adapter is not exported as Java.

### Local TCP simulation

Run `bundle exec ruby examples/modbus_tcp_simulator.rb` from the MXRB root.
The simulator listens only on `127.0.0.1:1502`, with `unit_id: 1` and addresses
0–255 in each area. A numeric argument changes the port. Coils and holding
registers start at zero and retain writes until shutdown; discrete input 0
starts as `true` and input register 0 as `1234`.

In another Ruby process, after `require 'mxrb'`:

```ruby
client = Mxrb::Modbus::Client.new(transport: :tcp, host: '127.0.0.1', port: 1502)
client.write_multiple_registers(0, [42, 123])
p client.read_holding_registers(0, 2) # [42, 123]
```

The simulator is a development tool with in-memory state. Stop it with Ctrl+C.

For the complete application flow, run
`bundle exec ruby examples/modbus_application.rb`. It starts its own simulator on
an available port, generates and validates an MPR with a `Measurement` entity and
the `Industrial.ConfigureAndSample` microflow, writes setpoints 42 and 84, and
saves the readings to SQLite. It then reopens the database and verifies both
measurements. The JSON result includes the model and database paths, retained in
a temporary directory for inspection. The simulator stops automatically.

### RTU serial port

RTU accepts an already open serial IO configured by the application/system in
raw mode, 8E1, 8O1 or 8N2, without local echo. The adapter must handle RS-485
direction control. `baud_rate` describes the configured speed for timing calculations;
it does not configure the port. No particular serial library is required.
POSIX example for an already configured port:

```ruby
File.open('/dev/ttyUSB0', File::RDWR | File::NONBLOCK | File::NOCTTY) do |serial|
  client = Mxrb::Modbus::Client.new(transport: :rtu, io: serial, baud_rate: 9600, unit_id: 1)
  p client.read_holding_registers(0, 2)
end
```

RTU requires `unit_id` 1–247; broadcast is unsupported. Use one client per bus;
concurrent calls are rejected until complete response validation finishes.
The caller owns and closes the IO. CRC, length, address and function are checked,
with software-observed frame separation and inter-character limits. Transport or
protocol errors invalidate the session: reopen and resynchronize the port before
creating another client; never automatically repeat an uncertain write. A valid
device exception does not invalidate the session. Tests use a pseudo-terminal and
local TCP; electrical timing, USB drivers and physical devices still require validation.

## Backend execution

Ruby mode runs the backend without starting the Mendix Java Runtime. When an
exported application opens, MXRB automatically migrates an environment-specific
SQLite database, opens the microflow interpreter, registers lifecycle hooks,
enforces security, and starts scheduled events.

Like the Runtime, the server runs the Model Settings after-startup microflow once,
without a user, before scheduled events; when it does not return `true` or fails
(for example on a Java action without an adapter), the application does not start.
`MXRB_AFTER_STARTUP=skip` starts without it during a migration. The before-shutdown
microflow runs when the application closes, and its failures are only reported.

Profiles live under `config/environments/` and commonly use `development.env`,
`qa.env`, `staging.env`, and `production.env`. Precedence is process environment,
profile file, `.env.<profile>`, then `.env`. Select one with `--environment qa`
or `MXRB_ENV=qa`; `mxrb env . --environment qa` shows sources and key names but
never values.

```bash
mxrb run . --environment qa
mxrb test App.mpr smoke.rb --native --environment qa
```

During `mxrb run`, the backend interprets Ruby sources and checks for changes
at each request boundary; Vite continues to own frontend HMR. A successful
reload swaps the application registry and runtime under one lock. If the new
code has a syntax error, an invalid declaration, or an unsafe migration, the
last valid revision keeps serving and `/api/health` reports the reload error.
Use `--no-reload` to pin the process to one source revision.

This development loop neither writes the `.mpr` nor invokes MxBuild. The
`.mpr` is synchronized only at the explicit `mxrb export` boundary. Until then,
Ruby pages, services, and models run in the backend, while native artifacts
without Ruby implementations continue through the interpreter from the
exported Mendix snapshot.

Each profile defaults to `.mxrb/runtime/<environment>.sqlite3`. Schema migration
derives entities, attributes, associations, and system members; additive changes
are idempotent and incompatible changes use a transactional rebuild. Non-
persistent entities remain in memory.

The Ruby API provides login and bearer tokens, sessions, schema, navigation,
pages, microflows, CRUD, and published REST. Page and microflow roles, entity
access rules and member rights are enforced for every request. Access rule
constraints use the same XPath engine as retrieves (associations, functions and
quoted tokens such as `'[%CurrentUser%]'`); a constraint that cannot be evaluated
denies access. Credentials come from `MXRB_USERS_JSON` and `MXRB_AUTH_TOKENS` and
should be supplied by ignored local files or the deployment secret manager.

Scheduled events use MXRB's stdlib scheduler with minute, hour, and day
intervals, overlap protection, and supervised shutdown. IANA time zones such
as `America/New_York` use `tzinfo`, including daylight-saving transitions.
Unknown zones fail during scheduling instead of silently falling back to UTC;
`UTC`, `local`, and numeric offsets such as `-04:00` are also supported.

Each request runs in its session's time zone: the user's `System.TimeZone` when
set, otherwise the IANA zone the browser sends in `X-Mxrb-Time-Zone`, otherwise
UTC; `/api/session` reports it. The Runtime's `System.TimeZone` objects are created
at startup, and new users get the project's default time zone, as in Studio Pro.

Sessions and scheduler coordination default to the native shared SQLite file
`.mxrb/runtime/<environment>-shared.sqlite3`, with no external service. Multiple
instances must point `MXRB_SHARED_STORE_PATH` to the same file. Idempotent
event-slot claims and heartbeat-renewed overlap leases are atomic; an unfinished
claim can be recovered after its lease expires. The default lease is 300 seconds
and can be changed with `MXRB_SCHEDULER_LEASE_TTL`. Set the shared-store path to
`:memory:`, `memory`, or `local` for explicit process-local mode.

By default, Java Custom Actions never start a JVM. Every permitted action must
have an explicit Ruby adapter registered by qualified name in `config/adapters.rb`:

```ruby
Mxrb::RubyApp::Registry.register_java_custom_action('Orders.CalculateTotal') do |arguments|
  Calculator.call(
    items: arguments.fetch('Items'),
    discount: arguments.fetch('Discount')
  )
end
```

Keys are the parameter names from the Mendix model. Basic values are evaluated
in the microflow context; entity, microflow, and mapping references are passed
as qualified names. The return value is assigned only when `UseReturnVariable`
is enabled (or for the legacy shape that only declares `ResultVariableName`).
An unregistered action fails closed with its name and registration guidance;
without the optional sidecar described below, there is no class discovery, JAR
execution, or JVM fallback. REST, app services,
SOAP, mappings, and document generation continue to use type-level Ruby
adapters. The browser still runs JavaScript/React, while its backend and APIs run
without the Java Runtime.

### Verified actions and the microflow context

Actions of Marketplace modules whose sources MXRB audited get ready-made Ruby
adapters. The export compares the SHA-256 of each action, and of the helper
classes it calls, with the audited releases and writes the registrations to
`config/verified_adapters.rb`. That file is rebuilt on every export and is not
embedded in the MPR, so a round trip picks up actions audited later. It loads
before `config/adapters.rb`; a registration there replaces the verified one of
the same name.

CommunityCommons has 19 actions audited in releases 9.0.1 and 11.5.1, including
the differences between them: `Base64Encode`, `EndTransaction`,
`GetApplicationUrl`, `GetModelVersion`, `GetRuntimeVersion`, `Hash`,
`RandomHash`, `RandomString`, `RandomStrongPassword`, `StringFromFile`,
`StringLeftPad`, `StringSplit`, `StringTrim`, `ThrowException`,
`TimeMeasureStart`, `TimeMeasureEnd`, `copyAttributes`,
`executeUnverifiedMicroflowAsUser_2` and `objectHasChanged`. From Encryption,
`EncryptString` and `DecryptString` (releases 8.0.2 and 10.0.2) encrypt `{AES3}`
with AES/GCM and also decrypt legacy `{AES}` (AES/CBC), interchangeably with the
Java code; `{AES2}` fails as on a freshly started 11.12.1 Runtime, which lacks the
`AES/GCM/PKCS5PADDING` cipher. The PGP actions have no adapter. At startup,
`UnitTesting.IsEnabled`, `Initialize`, `IsInitialized` and
`RegisterModelUpdateSubscriber` (10.0.4) follow the `UnitTesting.Enabled` constant,
and `OIDC.DeleteExpiredAuthAttempts` (3.3.1) deletes expired attempts.
`MxModelReflection.SyncObjects` (6.2.0 and 8.0.2) ports the module's builder over the
application's metamodel, which reproduces what the 11.12.1 Runtime reports
(`spec/fixtures/native_metamodel`); the System module comes from that Runtime, also
for projects of other versions.

An adapter that needs the calling microflow uses `with_context: true` and
receives `context:`, with the store, the log, other microflows (also as another
user or in a sudo context), the end of the transaction, the changed state of
objects, file contents and the application URL (`MXRB_APPLICATION_ROOT_URL`,
else the Ruby server address). Java exceptions are
`Mxrb::Runtime::JavaActionError` carrying the Java class name. Measured on the
11.12.1 Runtime and reproduced by the Ruby app
(`spec/fixtures/native_java_action_runtime`):

- `$latestError/ErrorType` is the qualified Java class name and
  `$latestError/Message` the exception message;
- `isChanged` marks an object when a member is set, even to the value it already
  had, until the next commit; a new object without set values is unchanged;
- `IContext.endTransaction` commits the transaction, except inside a
  sub-microflow called with custom error handling, whose savepoint keeps it open;
  after it, every commit is immediate;
- `Core.getModelVersion` is `unversioned` outside a deployment
  (`MXRB_MODEL_VERSION` sets another value);
- with custom error handling, a failed sub-microflow call is undone to its
  savepoint (without rollback) or undoes the whole transaction (with rollback,
  `rescue_all(rollback: true)`), and the error flow continues, in a new
  transaction in the latter case; a failed Java action keeps its commits, and
  after the end of the transaction the handled call runs in a transaction of its
  own (`spec/fixtures/native_error_handling_transactions`).

### Optional sidecar for the project's Java

Ruby adapters are limited to the audited Marketplace modules above. The
project's own Java, and that of modules not audited yet, can run in the sidecar
of `docker/java-actions`: a separate Java process (a container) used only when
`MXRB_JAVA_ACTIONS_URL` points at it (`tcp://host:port`). Without that variable
nothing changes: an action without an adapter fails closed. Actions resolve to
the adapter in `config/adapters.rb`, then the verified adapter, the platform
action, the sidecar and, last, the error.

The sidecar compiles the project's `javasource` and `userlib` against its own API
with the parts of `com.mendix.*` that actions use. The sidecar holds no Mendix
jar. The API covers:

- `IContext`, `ISession`, `UserAction`/`CustomJavaAction`, `ILogNode` and
  `FeedbackHelper`, whose message becomes the calling microflow's show-message;
- `IMendixObject` and `IMendixIdentifier`, including `getMembers`, the
  `MendixString`, `MendixInteger`, `MendixEnum`, `MendixObjectReference` and other
  members, `getState`, `isNew` and `getOriginalValue`, compared with the last commit;
- the metadata (`IMetaObject`, `IMetaPrimitive`, `IMetaAssociation`,
  `IMetaEnumeration`, `IDataType`), from the application's metamodel;
- in `Core`: the XPath retrieves (`createXPathQuery`, `retrieveXPathQuery`,
  `retrieveXPathQueryAggregate`, `retrieveByPath`, `retrieveId`), `instantiate`,
  `commit`, `delete`, `rollback`, `microflowCall`, the configuration, constants,
  versions (also `RuntimeVersion`), `getMetaObject(s)`, `getInputParameters`,
  `getReturnType`, `createDataType`, `getInternationalizedString` and file
  document contents (`getFileDocumentContent`, `storeFileDocumentContent`);
- tabular OQL (`retrieveOQLDataTable`, `createOQLTextGetRequest`,
  `createOQLTextGetRequestFromDataSet`, `IDataTable`, `IDataRow`, `IParameterMap`),
  run by the Ruby application's OQL engine; an ID column holds the object's
  identifier;
- request handlers: `Core.addRequestHandler` registers the path, and the Ruby
  application's server forwards its requests (outside `/api`, without a CSRF
  token) to the `RequestHandler`, with `IMxRuntimeRequest`/`IMxRuntimeResponse`
  and the session of the `mxrb_session` cookie; `Core.initializeGuestSession` opens
  a guest session when the project's security lets guests in, and its id is the
  cookie's value;
- `IMendixIdentifier.toLong` and `Core.createMendixIdentifier`, with the number
  kept in the application's database; `Core.getDefaultLanguage`,
  `Core.initializeSession` (microflows called with its contexts run as that user),
  `Core.executeAsync` (the sidecar runs the microflow before it answers) and
  transactions the action starts, nested in the calling microflow's.

Generated proxies also have `load(context, xpath)`, as Studio Pro's do. The
`org.json` Mendix bundles as `com.mendix.thirdparty.org.json` (`JSONObject`,
`JSONArray`, `JSONException`) has the sidecar's own implementation, and
`IContext.getRuntimeRequest`/`getRuntimeResponse` are empty, since the Ruby
application does not hand the HTTP request to actions.

A source that uses another API does not compile and is left out, with its first
error in `build-report.tsv`; calling that action raises an error that quotes the
reason. Enumeration captions follow the Ruby application's translations; the
proxies Studio Pro generates use the text id of each caption, and the package
records which value each id captions in `captions.tsv`.

The Ruby application remains the Runtime. Each call opens a connection carrying
JSON messages, one per line. The Java side gets handles to the microflow's
objects and reads, changes, commits, retrieves and calls microflows through
callbacks, so the transaction, events, entity access and log stay in Ruby. A
microflow the Java side calls may call another Java action, which runs on a
connection of its own. Integer attributes arrive as `java.lang.Integer`, empty
reference sets as an empty list, and the exception an action throws becomes
`$latestError` with its Java class. `MXRB_JAVA_ACTIONS_TOKEN`, when set on both
sides, authenticates calls; `MXRB_JAVA_ACTIONS_TIMEOUT` (300 s by default) bounds
the wait for each message. The `spec/fixtures/java_action_sidecar` case compiles
and runs real actions against the Ruby application.

`mxrb java-actions App.mpr app-ruby` prepares the sidecar of an exported
application without changing the export, which still holds no Java file. The
command writes to `java-actions/` the sidecar's Dockerfile and sources, a copy of
the project's `javasource` (sources that are not UTF-8 are read as ISO-8859-1)
with the proxies Studio Pro would generate and projects do not version, and the
`userlib` jars. It also creates a `docker-compose.yml`, unless one exists, with
the `java-actions` service on `127.0.0.1:7911`. The directory is rewritten on each
run and is not embedded in the MPR:

```sh
mxrb java-actions App.mpr app-ruby
cd app-ruby && docker compose up -d java-actions
```

Set the URL in the application's environment profile:

```sh
# config/environments/development.env
MXRB_JAVA_ACTIONS_URL=tcp://127.0.0.1:7911
```

## Ruby → Mendix → Ruby certification

The reproducible certification scenario lives in
[`spec/fixtures/flymetothemoon/project.rb`](../../spec/fixtures/flymetothemoon/project.rb).
It models customers, products, orders, and order lines in Ruby, including an
enumeration, indexes, associations, microflows, a nanoflow, a scheduled event,
and a data-grid page. The
[`spec/flymetothemoon_roundtrip_spec.rb`](../../spec/flymetothemoon_roundtrip_spec.rb)
test verifies these use cases:

- generate and validate a Mendix 11.12.1 MPR from the Ruby DSL;
- export through the real CLI with `--mode ruby --flymetothemoon`;
- require Sinatra, Puma, ActiveRecord, and RSpec while producing no Java, JAR,
  or bytecode files;
- execute creation, aggregation, branching, CRUD, and page metadata through the
  Ruby Runtime and SQLite;
- compile an unchanged app and structurally compare the MPR with its source;
- add an attribute and replace a microflow with idiomatic Ruby;
- export once more and prove that both the Ruby code and Mendix model survive a
  second structurally identical round trip.

Run the isolated case with:

```bash
bundle exec rspec spec/flymetothemoon_roundtrip_spec.rb
```

For generated interfaces, the declarative
[`spec/fixtures/frontend_browser/sudoku_full_flow.json`](../../spec/fixtures/frontend_browser/sudoku_full_flow.json)
scenario runs through `script/frontend_browser_acceptance` in a real Chromium.
It covers board positions 73 and 74, selection, value entry, and Easy, Medium,
and Hard transitions. Each critical click waits for the microflow POST plus the
association GET and must finish within 250 ms. Gallery queries are filtered by
context in SQLite; objects loaded through an inverse association retain that
link when only attributes are committed.
