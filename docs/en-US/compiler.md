# Compiler and MDA format

`mxrb pack App.mpr --output build/App.mda` writes a deterministic MDA ZIP in
pure Ruby. `mxrb mda inspect` inventories it and `mxrb mda compare` compares
entries by content.

This first stage requires an already materialized `deployment/` containing
`model/model.mdp`, `model/metadata.json`, `model/bundles/project.jar`, and
`web/index.html`. It never invokes `mx`, `mxbuild`, Studio Pro, or the Model SDK
as a fallback. Only the official `model`, `web`, `native`, `sass`, and `tmp`
roots are archived; Runtime and Gradle working directories are excluded.

Adapters currently cover Mendix 9.x, 10.x, and 11.x. Native materialization of
domain metadata, microflows, frontend bundles, Java artifacts, and the portable
Runtime remains explicit follow-up work. VetClinic's MXRB-written MDA was
accepted by Runtime 11.12.1, synchronized 675 database operations, and served
HTTP 200.
