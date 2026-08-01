# Native compiler, Runtime, and MDA format

MXRB's functional pipeline does not execute `mx`, `mxbuild`, `mxcli`, Studio
Pro, or the Model SDK. Those tools may remain external compatibility gates, but
they are not build, database, or functional-test dependencies.

## Clean build

`DeploymentMaterializer` creates a missing `deployment/` from the installed
version templates and runs 12 stages: security, constants, domain model,
artifacts, translations, system texts, system queues, client model, actions,
settings, microflows, and the project/module index. It also creates metadata,
dependency files, and a Runtime-ordered BSON `model.mdp`.

Bootstrap has audited seeds and catalogs for 6.10.8, 7.5.0, 7.17.0,
9.6.1.29396, and 11.12.1. The 6.x, 7.x, 9.x, and 11.x families select a
compatible compiler seed; 5.x, 8.x, and 10.x fail closed without an audited
seed. Family selection applies to compiler schema only. Runtime must always
match the MPR's exact patch.

`ProjectJarBuilder` discovers the JDK through `MXRB_JAVA_HOME`, `JAVA_HOME`,
asdf, or mise, compiles `javasource/**/*.java` against Runtime and project
libraries, and writes a deterministic OSGi `project.jar`. VetClinic compiled
183 sources into 249 classes.

`WebBundleBuilder` selects Dojo for 6/7, Dojo plus the React wrapper for 9, and
React for 11. The React path generates entrypoint/page modules, expands `.mpk`,
and invokes the version-owned Node/Rspack directly. Data Grid 2 compiles for the XPath datasource and attribute-column
subset, including `operations.json`, datasource, and attribute types.
Untranslated types or property combinations receive a DOM fallback and are
recorded in `web/mxrb-pages.json`; VetClinic's manifest is empty.

The Dojo path compiles Data Grid 1 database, XPath, and microflow sources plus
audited search, sorting, paging, selection, and buttons. Every other visible
widget is recorded per page in `web/mxrb-legacy-pages.json` and is not claimed
as rendered.

## MDA and portable package

```bash
mxrb pack App.mpr --output build/App.mda
mxrb mda inspect build/App.mda
mxrb portable App.mpr --output build/runtime.zip
```

MDA and portable ZIP output is deterministic. The portable package combines
the native deployment with the installed matching Runtime, generated settings,
constants, and scripts. MDA output includes only official roots; working
directories such as `data`, `log`, `run`, `build`, and `.gradle` are excluded.

## Regression evidence

```bash
script/runtime_boot_regression App.mpr /missing/deployment \
  ~/.local/share/mendix/11.12.1
```

The regression creates a temporary deployment, compiles Java and web output,
packages it, starts Runtime, and requires HTTP 200 for `/`, `dist/index.js`, and
every generated page bundle. It also requires a clean shutdown. The transcript
and SHA-256 are written to `tmp/runtime-boot-evidence.log`. When Chromium is
installed, it imports every module and instantiates factories that do not need
a session. The Data Grid bundle is imported and evaluated; its factory reads
the client session and therefore requires an authenticated test to instantiate.

On August 1, 2026, VetClinic 11.12.1 started from no deployment, executed 675
database synchronization commands, initialized the `System` queues, scheduled
`VetClinic.Cleanup`, returned 200 for all four page bundles, and shut down
cleanly. The `ACT Create Animal` functional test then passed.

## Explicit boundaries

- all 12 stages and clean web generation are validated on 6.10.8, 7.5.0,
  7.17.0, 9.6.1.29396, and 11.12.1;
- exact native boot is proven on 11.12.1. The installed 6/7/9 distributions
  contain the exact Runtime bundles but no PAD/launcher; `db up` fails closed
  instead of substituting the Java-21 launcher from 11;
- Data Grid 1 is covered while other Dojo widgets remain explicit manifest
  findings;
- Data Grid 2 is covered for XPath datasource and attribute columns; other
  widgets and property combinations use the manifest-recorded fallback;
- native web bundles are generated; React Native still relies on existing
  version-template and project assets;
- `mx` and `mxbuild` are never fallbacks. Unsupported input produces a clear
  compiler error or a support-manifest entry.
