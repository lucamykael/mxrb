# Exported project structure

The Ruby tree produced by `mxrb export` separates app-wide policy, module
behavior, preserved native units and filesystem assets:

```text
project.rb
.mxrb/
  native_units.json
  native_units.rb
  assets.json
app/
  security/security.rb
  navigation/navigation.rb
  design_system/design_system.rb
modules/
  ModuleName/
    domain/
    application/
    presentation/
    infrastructure/
    security/
theme/
themesource/
resources/
widgets/
javasource/
javascriptsource/
```

`project.rb` is orchestration. Module files own model behavior. The native
manifest preserves structures without a concise typed DSL. The asset manifest
records relative paths, sizes and SHA-256 digests for every copied project
asset.

Reconstruction validates every asset path and digest, then writes only the
manifest entries. Absolute paths, parent traversal, missing sources and
checksum mismatches fail closed.

The same tree supports all four normal workflows:

- Ruby definition to a new Mendix project;
- Ruby changes over an exported Mendix baseline;
- Mendix project to editable Ruby;
- Mendix export to Ruby and back to a structurally equivalent Mendix project.

[Back to the documentation index](README.md)
