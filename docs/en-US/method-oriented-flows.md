# Method-oriented microflows and nanoflows

[Português](../pt-BR/method-oriented-flows.md)

New flow exports expose the sequence in `main_line`, put activities in named Ruby
methods, and move parameters, result type, permissions and other declarations to
`flow_contract`. Useful Studio Pro activity captions become method names; generic
captions use the operation and its target. Names are sanitized, reserved names are
protected and collisions receive deterministic suffixes.

```ruby
def main_line
  load_order
  decide '$Approved', if_true: :approve_order, if_false: :reject_order
  commit_order
  return_value '$Order'
end
```

The call after `decide` is the common continuation after the merge. A branch with
one activity references that activity directly instead of adding a wrapper. Empty
branches and short exits can use lambdas:

```ruby
decide '$Skip', if_true: -> { return_value '-1' }, if_false: -> {}
loop_over :Orders, as: :Order, &step(:process_order)
call_microflow 'Sales.Summarize', as: :Summary, pass: { 'Sales.Summarize.Total' => '$Total' }
rescue_all rollback: true, &step(:handle_failure)
return_value '$Summary'
```

`step(:name)`, `step(method(:name))` and `step { ... }` bind a method or small block
to the correct typed branch/loop builder. `decide` also accepts Proc values.
For multiple case values use `cases: [['ready', :process], ['new', :prepare]]`.
The explicit `branches:` mapping remains accepted for manual authoring; exports
use `if_true:`/`if_false:` and `cases:` to avoid structure hashes in public source.
Loop control restrictions remain in effect across methods. Rule decisions retain
ordered argument mappings; inheritance decisions retain their types/default arm.

Services register their completed methods with `flow :microflow, main: :main_line`
(also `:nanoflow` and `:rule`). The Mendix export uses
`microflow :Name, plan: Class.new(Mxrb::Dsl::FlowProgram) { ... }`, keeping each
file's definitions isolated. `nanoflow` and `rule` also accept `plan:`.

These methods compose the authoritative typed model at Ruby project load time;
`Service#call` executes the resulting graph through MXRB's Ruby runtime. Strings
such as `'$Approved'` are Mendix expressions. Ruby `if '$Approved'` would always
be true and is deliberately not generated. Use `return_value` or `end_flow` for
flow exits; Ruby `return` only returns from a definition method.

Existing block declarations and `native` remain accepted. Supplying both a method
plan and a definition block is rejected. IDs, references and layout keep their
existing metadata sidecars. Round-trip tests compare exact native documents
before edits, then verify changed execution and unit identities after edits.
This source layout does not add support for previously unsupported graph shapes;
their diagnostics and previous limitations remain explicit.

Embedded application Ruby is preserved. Export an existing model to a new
directory to obtain the new style without overwriting an existing Ruby project.
See `spec/method_flow_source_spec.rb` and
`spec/runtime/microflow_oracles_spec.rb` for semantic execution evidence, including
merges, early exits, loops, calls, rollback, inheritance and callback isolation.
