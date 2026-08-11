# Java-free runtime

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
