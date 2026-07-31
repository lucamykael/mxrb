# Betrieb, Lifecycle und Marketplace

## Diagnose, Benchmark und Weiterentwicklung

```sh
mxrb doctor .
mxrb benchmark App.mpr --iterations 5 --json
mxrb project inspect . --json
mxrb upgrade --mendix 11.12.1 --target .
mxrb upgrade --mendix 11.12.1 --target . --apply
mxrb migrate plan .
mxrb migrate check .
```

`doctor` prüft Ruby-Projekt, Aggregatoren, MPR und lokale Toolchain.
`benchmark` misst Öffnen, semantische Indizierung und Validierung. Ein Upgrade
ist ohne `--apply` nur eine Vorschau. Migration erzeugt das Projekt temporär
und vergleicht es mit dem aktuellen MPR; `check` schlägt bei Modelldrift fehl.

## Offizieller und Community-Mendix-Marketplace

Der offizielle Web-Marketplace bietet keinen vollständigen stabilen
öffentlichen PAT-Downloadablauf. MXRB trennt deshalb folgende Funktionen:

```sh
mxrb marketplace search CommunityCommons
mxrb marketplace pull CommunityCommons
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr MeineApp.mpr
mxrb marketplace pull CommunityCommons --mpr MeineApp.mpr
mxrb marketplace list
mxrb marketplace verify
mxrb marketplace login
```

Mit `--mpr` liest MXRB `package.xml` und die eingebettete `project.mpr` und
importiert den vollständigen Modulbaum direkt über Ruby/SQLite/BSON. Dabei
werden weder `mx` noch `mxcli`, Studio Pro oder das Model SDK ausgeführt. IDs
bleiben erhalten, deklarierte Assets werden transaktional installiert und
Paketcache sowie Modulidentität im Lockfile gespeichert. Für den reinen
Ruby-Import müssen Paket und Ziel dieselbe Mendix-Modellversion verwenden.

`pull` löst öffentliche GitHub-Releases auf; `import` verarbeitet ein bereits
geladenes MPK/ZIP. Beide entpacken sicher, überschreiben nichts und sperren
Quelle, Version und SHA-256. `login` speichert den PAT außerhalb des Projekts
mit Modus `0600`; `pull` nutzt ihn derzeit nicht. Ruby-Pakete bleiben im
separaten Ablauf `mxrb module search/add`.
