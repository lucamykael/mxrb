# MXRB

**English** · [Português](README.pt-BR.md) · [Deutsch](README.de-DE.md)

MXRB is a Ruby-first toolkit for reading, writing, exporting, validating and
testing Mendix project models (`.mpr`) without using MDL or `mxcli`.

Ruby is the public interface. The official Mendix `mx`, `mxbuild` and Runtime
remain optional external gates for compatibility and functional execution.

## Current capabilities

- read and write MPR v1 and v2 projects;
- export complete projects into editable Ruby;
- generate idempotent MPRs from a Ruby DSL;
- scaffold a new Ruby-first project with its PascalCase application module;
- expose every native unit as editable deep Ruby while retaining a lossless baseline;
- compare structural snapshots and produce typed semantic diffs;
- inspect references, callers, callees and transitive impact;
- rename artifacts with a preview before applying changes;
- read and write native navigation profiles, role homes and recursive menus;
- preserve theme, widget, resource and Java assets with SHA-256 manifests;
- inventory design tokens, check contrast and preview atomic literal migration;
- discover native OQL and render safe logical SQL views only when OQL exists;
- materialize an isolated, Runtime-synchronized PostgreSQL for direct SQL inspection;
- analyze PostgreSQL/SQL Server plans and rank cumulative PostgreSQL workload pressure;
- move standalone units between folders in the same module with a preview;
- remove standalone units only after reference and child-unit safety checks;
- run static analysis and executable model evaluations in Ruby;
- execute functional microflow tests locally or in disposable containers.
- search and install reusable Ruby modules with a locked SHA-256 digest.
- write, inspect and compare deterministic MDA containers without invoking `mxbuild`;
- clone, inspect and synchronize official Team Server Git repositories while
  keeping PAT values in user-managed files.

The public validation matrix currently covers structural v1/v2 round trips
from Mendix 5.21 through 11.12 and official MxBuild checks where the native
toolchain is supported. Exact Mendix 5 validation still depends on
Windows/Studio Pro and remains a documented legacy limitation, but it is not a
current delivery gate. See
[the validation matrix](docs/en-US/validation-matrix.md) for the exact evidence and
confidence boundaries.

## Requirements

- Ruby 4.0 or newer;
- SQLite3;
- the exact Mendix Linux toolchain for official checks;
- Java matching the project when running locally, or Docker for containerized
  builds and runtime tests.

Install dependencies:

```sh
bundle install
```

## Ruby DSL

```ruby
Mxrb.define("Shop.mpr") do
  mendix_version "11.12.1"

  self.module :Sales do
    entity :Order do
      string :Number, documentation: "Stable order number"
      decimal :Total, default: 0
    end

    microflow :CreateOrder do
      return_type :Order
      create_object "Sales.Order", as: :order
      return_value :order
    end
  end
end
```

```sh
bundle exec mxrb generate shop.rb
bundle exec mxrb validate Shop.mpr
bundle exec mxrb export Shop.mpr exported-shop
bundle exec mxrb compare original.mpr rebuilt.mpr
bundle exec mxrb module search
bundle exec mxrb module add shared-kernel
bundle exec mxrb cache status Shop.mpr
bundle exec mxrb cache warm Shop.mpr
bundle exec mxrb cache clear Shop.mpr
bundle exec mxrb oql Shop.mpr --dialect postgresql
bundle exec mxrb db up Shop.mpr
bundle exec mxrb db sql Shop.mpr 'SELECT * FROM "sales$order" LIMIT 20'
bundle exec mxrb pack Shop.mpr --output build/Shop.mda
bundle exec mxrb team-server clone APP_ID ./shop --pat-file /secure/team-server.env
```

The MPR stores the model, not application data. `db up` builds the exact
portable Runtime and lets it synchronize an isolated PostgreSQL volume.
Database access is loopback-only and uses a read-only analyst role unless
`--write` is explicitly requested. See
[OQL and local SQL access](docs/en-US/oql-sql.md).

## Model evaluations

```ruby
# evaluation.rb
artifact "Sales.Order", kind: :entity
no_call_cycles
no_missing_internal_references

check "Order has a total" do |project|
  project.find_artifact("Sales.Order.Total", kind: :attribute)
end
```

```sh
bundle exec mxrb evaluate Shop.mpr evaluation.rb
```

## Functional microflow tests

Functional definitions are Ruby and do not require JUnit:

```ruby
# functional_test.rb
microflow "creates an order", call: "Sales.ACT_CreateOrder"
```

Run with the local toolchain:

```sh
JAVA_HOME=/path/to/jdk \
  bundle exec mxrb test Shop.mpr functional_test.rb
```

Or build and run inside disposable containers:

```sh
bundle exec mxrb test Shop.mpr functional_test.rb --docker
```

The source project is copied before instrumentation. `mx check`, the portable
package, runtime database and uploaded files are discarded after execution.
The functional scope verifies completion, exception handling, return values
and persisted state through entity/XPath count assertions.

## Development

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
bundle exec ruby script/branch_report.rb
bundle exec rubocop
```

The enforced suite currently has 100% line and branch coverage. The branch
report lists any regression by source file and line.

Architecture and deeper writing guidance are available in
[the English documentation](docs/en-US/README.md). The complete documentation
is also available in [Portuguese](docs/pt-BR/README.md) and
[German](docs/de-DE/README.md).

## License

MXRB is available under the MIT License.
