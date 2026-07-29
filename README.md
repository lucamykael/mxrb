# MXRB

MXRB is a Ruby-first toolkit for reading, writing, exporting, validating and
testing Mendix project models (`.mpr`) without using MDL or `mxcli`.

Ruby is the public interface. The official Mendix `mx`, `mxbuild` and Runtime
remain optional external gates for compatibility and functional execution.

## Current capabilities

- read and write MPR v1 and v2 projects;
- export complete projects into editable Ruby;
- generate idempotent MPRs from a Ruby DSL;
- preserve native units that do not yet have a concise typed abstraction;
- compare structural snapshots and produce typed semantic diffs;
- inspect references, callers, callees and transitive impact;
- rename artifacts with a preview before applying changes;
- run static analysis and executable model evaluations in Ruby;
- execute functional microflow tests locally or in disposable containers.

The public validation matrix currently covers Mendix 5.21 through 11.12,
including v1/v2 round trips and official MxBuild checks. See
[the validation matrix](docs/VALIDATION_MATRIX.md) for the exact evidence and
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
      string :Number, required: true
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
```

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
The current functional slice proves microflow completion and exception
handling; assertions over return values and persisted state are the next layer.

## Development

```sh
bundle exec rspec
MXRB_COVERAGE=1 bundle exec rspec
```

The enforced suite currently has 100% line coverage. Branch coverage is
reported separately and is not represented as 100%.

Architecture and deeper writing guidance are available in
[docs/writing.md](docs/writing.md) and
[docs/RUBY_FIRST_ROADMAP.md](docs/RUBY_FIRST_ROADMAP.md).

## License

MXRB is available under the MIT License.
