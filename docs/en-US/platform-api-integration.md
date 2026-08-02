# Mendix API integration assessment

Date: August 1, 2026. Source: the official [Mendix APIs and SDK index](https://docs.mendix.com/apidocs-mxsdk/).

## Decision matrix

| API or SDK | MXRB use | Decision |
| --- | --- | --- |
| Projects API | list accessible apps and project metadata | integrated as `team-server projects`; read-only by default |
| App Repository API | repository info, branches, and commits | integrated in Team Server discovery and clone flow |
| Marketplace Content API | discover and download modules/widgets | integrated in Marketplace operations |
| Build API | compare a native MXRB artifact with an official cloud build | optional external verification adapter; never a native-build dependency |
| Deploy API v4 | inventory apps/environments before release verification | proposed read-only adapter; mutations require explicit confirmation |
| Pipelines API | trigger and observe an existing CI/CD pipeline | proposed opt-in adapter with idempotency and status polling |
| Backups API v2 | list/create/download snapshots before deployment work | proposed safety adapter; restore/delete remain explicit destructive actions |
| Runtime API 11 | compile custom Java and verify Runtime contracts | used as a contract for proxy generation; it is a Java API, not a remote REST replacement |
| Client and Pluggable Widget APIs | define Dojo/React/Data Grid bundle contracts | reference contract for generated web artifacts, not an HTTP client |
| Catalog APIs | register or query governed external data sources | future plugin; outside native build/runtime |
| Model/Platform SDKs and Studio Pro extensibility | remotely model apps or extend Studio Pro | deliberately not required; MXRB remains Ruby/SQLite/BSON and standalone |

## Integration rules

- Remote calls are explicit; `generate`, `compile`, `validate`, and `db up` never contact Mendix Cloud.
- PATs/API keys come from a protected file or environment and are never written to reports, logs, generated projects, or Git.
- Read-only endpoints are the default. Build, deploy, pipeline, backup restore, project membership, and deletion operations require a dedicated command and confirmation appropriate to their impact.
- The Build API is limited to Mendix Cloud apps and uses account API-key authentication, so it cannot replace MXRB's local native compiler.
- Versioned Runtime and frontend APIs are compatibility evidence. MXRB keeps exact audited schemas/seeds and fails closed when a version contract or launcher is unavailable.

## Recommended order

1. App Repository branch/commit listing in `team-server`, completing the already integrated repository discovery.
2. A read-only Deploy inventory command and optional Build comparison gate.
3. Pipeline status/trigger with idempotency keys and bounded polling.
4. Backup list/create/download safeguards before any cloud mutation.

Catalog and Studio Pro extensibility remain separate adapters because they do not reduce native build/runtime dependency risk.
