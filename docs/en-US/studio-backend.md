# Studio backend protocol

[Português](../pt-BR/studio-backend.md) · **English** · [Deutsch](../de-DE/studio-backend.md)

`mxrb studio serve` runs MXRB as the backend of an IDE: a long-lived process
that speaks JSON-RPC 2.0 on stdin and stdout. Every IDE function that MXRB
owns (command catalog and tasks, Ruby project files, conversion, document
properties, typed model operations with undo and redo, Ruby/Mendix
synchronization, write coordination, ER and database queries) is one method
of `Mxrb::Studio::Service`. The IDE renders; MXRB decides and persists.

```sh
mxrb studio serve [--state-root DIR]
```

State (Ruby project links, synchronization bases, undo journals) lives under
`$XDG_STATE_HOME/mxrb/studio` unless `--state-root` is given.

## Framing and session

- One JSON-RPC message per line (NDJSON). JSON text never contains a raw
  newline, so a line is always a whole message.
- Requests run concurrently; replies can arrive in any order.
- The first request is `initialize`. The client states the protocol versions
  it speaks and, optionally, its workspace roots (used to attach file/line
  locations to errors):

```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocol_versions":[2],"roots":["/work/shop-ruby"]}}
```

The reply names the protocol (`mxrb-studio` 2), the server version, every
method, the notifications and the capabilities (cancellation, progress, fork
isolation, undo, sync, locks). A client that speaks no supported version
receives error `-32015` with `data.supported`.

- `shutdown` waits for running requests and then refuses new ones; the `exit`
  notification ends the process. Closing stdin cancels what is still running.

## Methods

| Group | Methods |
|---|---|
| Catalog and tasks | `catalog/list`, `catalog/arguments`, `tasks/prepare`, `tasks/run`, `tasks/input` |
| Files | `files/list`, `files/read`, `files/write`, `files/create`, `files/move`, `files/worktrees` |
| Ruby | `ruby/syntax`, `ruby/declarations` |
| Project | `snapshot/create`, `project/status`, `project/convert`, `project/attach` |
| Documents | `documents/list`, `documents/read`, `documents/patch` |
| Model | `model/capabilities`, `model/revision`, `model/preview`, `model/apply`, `model/history`, `model/undo`, `model/redo`, `model/catalog`, `model/domainDiagram` |
| Data | `data/logical`, `data/physical`, `data/query`, `data/explain` |
| Sync | `sync/link`, `sync/unlink`, `sync/status`, `sync/run` |
| Locks | `locks/acquire`, `locks/release`, `locks/status` |

`catalog/list` returns every public CLI command and scaffold with a typed
argument schema; `tasks/run` executes one as a child process and streams
`tasks/started` and `tasks/output` notifications. Cancelling the request
stops the task (`cancelled: true` in the result).

`ruby/syntax` parses with Prism and returns diagnostics with line and column;
`ruby/declarations` lists the Mendix artifacts a file declares (`entity`,
`page`, `microflow`, ...) with their qualified names. Neither evaluates Ruby.

`files/write` and `documents/patch` take the revision the client last read
and fail with a conflict when the file or unit changed in between, so both
versions are kept.

## Progress, cancellation and errors

- `$/cancelRequest` with `{"id": ...}` cancels a request.
- Long operations report `$/progress` notifications
  (`token` = request id, `kind` = `begin`/`report`/`end`, `current`, `total`,
  `detail`). Every MXRB operation that reports terminal progress reports here,
  and each report is a cancellation point.
- Evaluating a Ruby project and exporting a model run in a forked worker: a
  definition that exits, loops or exhausts memory cannot take the server down,
  and cancelling terminates the worker.

Errors are JSON-RPC error objects with `data.kind` and, when known,
`data.locations` (`file`, `line`, `column`):

| Code | `kind` | Meaning |
|---|---|---|
| -32700 / -32600 / -32601 / -32602 | `parse_error` / `invalid_request` / `method_not_found` / `invalid_params` | JSON-RPC conditions |
| -32002 | `not_initialized` | a request before `initialize` |
| -32800 | `cancelled` | the request was cancelled |
| -32010 | `conflict` | the target changed since it was read; nothing was overwritten |
| -32011 | `busy` | another writer holds the model; retry |
| -32012 | `validation` | the model or operation is invalid |
| -32013 | `toolchain` | a required tool or system call failed |
| -32014 | `ruby_source` | Ruby does not parse or evaluate; see `locations` |
| -32015 | `unsupported_protocol` | no common protocol version |
| -32603 | `internal_error` | anything else |

## Coordinated writes

Every MXRB writer of a model or workspace takes an exclusive `flock` on
`$XDG_STATE_HOME/mxrb/studio/locks/<sha256 of the canonical path>`. An IDE
that saves the same model takes the same lock, either directly or through
`locks/acquire` (the server holds the lock for the lease until
`locks/release` or the end of the connection). `locks/status` reports whether
someone holds it. MXRB waits up to 30 seconds and then answers `busy`.

## Undo and redo

`model/apply`, `documents/patch` and `sync/run` record a journal entry with the
exact native bytes of every unit they added, removed or changed. `model/undo`
restores them byte for byte (IDs, references and layout included);
`model/redo` reapplies them. An entry is only undone while its units still
hold the state it left; otherwise the request fails with a conflict and
nothing is written. The journal keeps the last 100 entries.

## Ruby and Mendix synchronization

`sync/link` records the synchronized base of a model and its Ruby project: a
copy of the model, a copy of the Ruby files, the Ruby export of the model and
the model generated from the Ruby. `sync/status` is cheap: changed Ruby files
with their parse diagnostics and declared artifacts, changed Mendix units and
unresolved conflicts, summarized as `synced`, `pending`, `conversion_error` or
`conflict`.

`sync/run` synchronizes both directions:

1. **Mendix edits** are the units whose meaning differs from the base model.
   Property order, freshly generated IDs and the order of entities do not
   count as changes.
2. **Ruby edits** are the units whose generation from the current Ruby differs
   from the generation of the base Ruby. They are expressed as element
   operations (set a property, insert, remove or reorder a child) in the IDs
   of the model, so applying them keeps IDs, references, layout and every
   untouched property. Deleting the Ruby declaration of a document removes the
   document.
3. An element both sides changed is a **conflict**. A run with conflicts
   writes nothing and returns each conflict with the base, Mendix and Ruby
   values (`kind` `element`, `unit` or `file`). Running again with
   `resolutions` (`{"<conflict id>": "ruby" | "mendix"}`) applies everything.
4. Ruby edits are applied to the model in one journaled transaction, under the
   write lock, only if the model did not change during the run.
5. Mendix edits are merged into the Ruby files with a line-based three-way
   merge: comments and Ruby code outside the changed lines stay as they are. A
   change on one side next to an insertion on the other is not a conflict.
   Files that are overwritten are copied to the base's backup folder first.
6. `.mxrb/` (the native baseline and asset manifest) is owned by MXRB and
   always mirrors the synchronized model.

Ruby that does not parse or evaluate leaves the model untouched; the run fails
with `ruby_source` and the locations of the error. The last valid model stays
as it is and the Ruby changes stay pending.

`sync/status` also reports `diverged` units: units where the model generated
from the synchronized Ruby means something different from the model itself.
They show which parts of a model the Ruby projection does not capture yet;
their native content is preserved, not converted.

Measured on the public Sudoku sample (409 units, 355 Ruby files, Ruby 4.0,
one core per worker): linking 23 s, Ruby to Mendix 21 s (dominated by
generating the whole project from Ruby), Mendix to Ruby 5 s, `sync/status`
0.2 s.

## Single-shot use

`Mxrb::Studio::Backend#call` accepts one request object with a version 1
`action` name (`catalog`, `file_read`, `model_apply`, ...) and reaches the same
methods, for clients that start one process per request.

[Back to the documentation index](README.md)
