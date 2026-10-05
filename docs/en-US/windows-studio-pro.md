# Windows and Studio Pro validation with Omarchy

## Verified on October 5, 2026

The existing Windows VM on the USB drive was reused with its installed Studio
Pro 11.12.1. No reinstall or disk formatting is needed. RDP ran in a dedicated
Xvfb server (`DISPLAY=:97`) without using or changing the user's physical
screens. Keep credentials out of commands and reports. Copy projects to a
local Windows directory before opening them: converting/writing external units
on an RDP shared drive can fail.

All six native builds passed: source and Ruby round-trip versions of the
contracts, native presentation and core-widget fixtures. Native Runtime returned
HTTP 200, rendered its page and passed client API create/read/update/delete in
headless Edge. GUI checks covered popup arguments/shared context, closing two
windows and asynchronous completion. VetClinic also passed builds, themed
rendering and client API CRUD. These checks do not certify every form, theme,
mobile layout or widget variant.

The [versioned report](../evidence/native-2026-10-05.json) records that scope.

## Reproduce

Generate a new destination on Linux and transport the entire folder to Windows.
Adjust the installed tool paths below:

```bash
bundle exec ruby script/studio_pro_batch /tmp/native-batch
```

```powershell
./script/studio_pro_gate.ps1 -BatchDirectory C:\incoming\native-batch `
  -WorkspaceRoot C:\mxrb-projects -StudioVersion 11.12.1
./script/studio_pro_runtime.ps1 `
  -Package C:\incoming\native-batch\results\core-widgets-roundtrip\core-widgets-roundtrip.mda `
  -ToolRoot C:\Mendix\11.12.1 -JavaHome C:\Java\jdk-21 `
  -EvidenceDirectory C:\incoming\runtime-evidence
```

The gate verifies executable versions and signatures, every transported file
hash, `mprcontents` ownership and the physical `.mxunit` count. It builds local
copies and rechecks the inputs afterward. Existing destinations are refused.
A tampered unit was rejected before building. `results` contains summaries,
logs, errors and packages; the runtime check adds `runtime.json` and a page
screenshot. It stops only its own processes and uses a disposable HSQLDB
database and Edge profile.

## CI

[Windows native certification](../../.github/workflows/studio-pro.yml) runs
weekly, manually and on relevant PRs. Hosted Windows uses the official MxBuild
11.12.1 archive pinned by SHA-256, JDK 21 and headless Edge. The current matrix checks eight builds (including validation rules)
and boots both source and rebuilt core packages. Evidence artifacts are retained
for 14 days. This job does not install the Studio Pro GUI; visual certification
is recorded separately.

Keep the Ruby gates at 100% line and branch coverage, along with frontend and
Chromium checks. Start the existing VM with the installed Omarchy commands and
use a separate virtual display for further GUI work.
