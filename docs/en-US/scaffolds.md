# Project scaffolds

[Português](../pt-BR/scaffolds.md) · **English** · [Deutsch](../de-DE/scaffolds.md)

Every command accepts `--target DIR`, refuses to overwrite files, and wires
`evaluate`/`evaluate_dir` aggregators automatically. Run
`mxrb <command> --help` for usage, destination, and options.

The available families are project/module (`init`, `module new`), domain
(`entity`, `enumeration`, `constant`), application (`use-case`, `validation`,
`query`, `repository`, `scheduled-event`), presentation (`presentation init`,
`page`, `nanoflow`), security, infrastructure (`integration`, `published-rest`,
`consumed-rest`, `java-action`), verification (`functional-test`, `evaluation`),
design, and GitHub CI.

Artifact commands use `new Module.Name`; project commands use `design init` and
`ci init github`. See the [entity DSL](entity-dsl.md) for all supported entity
types and associations. Published REST and Java Action create editable Ruby
adapters; their native document/action must still come from an exported
baseline or Studio Pro.
