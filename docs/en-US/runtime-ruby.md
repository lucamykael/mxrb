# Java-free runtime

## Modbus TCP

`Mxrb::Modbus::Client` is MXRB's own Ruby backend connector for functions
01/02/03/04/05/06/15/16 of the
[Modbus specification](https://www.modbus.org/modbus-specifications).
It is not an official Marketplace package and does not generate Mendix Java code.
RTU/serial, TLS and register-to-float conversions are outside this API.

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

Each operation opens and closes its connection with one total deadline in seconds
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

## Backend execution

Ruby mode runs the backend without starting the Mendix Java Runtime. When an
exported application opens, MXRB automatically migrates an environment-specific
SQLite database, opens the microflow interpreter, registers lifecycle hooks,
enforces security, and starts scheduled events.

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
access rules, member rights, and the safe XPath subset are enforced for every
request. Credentials come from `MXRB_USERS_JSON` and `MXRB_AUTH_TOKENS` and
should be supplied by ignored local files or the deployment secret manager.

Scheduled events use MXRB's stdlib scheduler with minute, hour, and day
intervals, overlap protection, and supervised shutdown. IANA time zones such
as `America/New_York` use `tzinfo`, including daylight-saving transitions.
Unknown zones fail during scheduling instead of silently falling back to UTC;
`UTC`, `local`, and numeric offsets such as `-04:00` are also supported.

Sessions and scheduler coordination default to the native shared SQLite file
`.mxrb/runtime/<environment>-shared.sqlite3`, with no external service. Multiple
instances must point `MXRB_SHARED_STORE_PATH` to the same file. Idempotent
event-slot claims and heartbeat-renewed overlap leases are atomic; an unfinished
claim can be recovered after its lease expires. The default lease is 300 seconds
and can be changed with `MXRB_SCHEDULER_LEASE_TTL`. Set the shared-store path to
`:memory:`, `memory`, or `local` for explicit process-local mode.

Java Custom Actions never start a JVM. Every permitted action must have an
explicit Ruby adapter registered by qualified name in `config/adapters.rb`:

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
there is no class discovery, JAR execution, or JVM fallback. REST, app services,
SOAP, mappings, and document generation continue to use type-level Ruby
adapters. The browser still runs JavaScript/React, while its backend and APIs run
without the Java Runtime.

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
