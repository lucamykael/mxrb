# Windows and Studio Pro validation with Omarchy

Verified on August 12, 2026: AMD-V and KVM are available. Omarchy provides:

```bash
omarchy windows vm install
```

The standard installer uses `dockurr/windows`, RDP, and `~/Windows`, and requires
74 GB free. The root filesystem had 60 GB free, so no VM was installed. The
secondary ext4 SSD had 435 GB free; it was inspected read-only and unmounted
without changes. Continue only after deliberately freeing at least 14 GB on the
root filesystem or approving a writable VM location on the secondary SSD.

Once capacity is resolved:

```bash
omarchy windows vm install
omarchy windows vm status
omarchy windows vm start
```

In Studio Pro, open a copy with the matching version, synchronize the App
Directory, inspect domain rules, pages, navigation, microflows, and nanoflows,
then build and test page → nanoflow → microflow → visible result. GUI validation
complements, but does not replace, the Linux, Docker, TypeScript, Chromium, and
`mxbuild` gates.
