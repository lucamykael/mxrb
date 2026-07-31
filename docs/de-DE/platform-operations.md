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

MXRB verwendet die dokumentierte Mendix Marketplace Content API. Das PAT
benötigt den Scope `mx:marketplace-content:read`:

```sh
cp .env.example .env
# MXRB_MENDIX_PAT in .env setzen; die Datei nie committen.
mxrb marketplace login --pat-file .env
mxrb marketplace search "Community Commons"
mxrb marketplace show 170
mxrb marketplace versions 170 --mendix-version 11.12.1
mxrb marketplace pull 170 --mpr MeineApp.mpr
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr MeineApp.mpr
mxrb marketplace audit --target . --mendix-version 11.12.1
mxrb marketplace list
mxrb marketplace verify
```

Der empfohlene Login speichert ausschließlich den absoluten `.env`-Pfad in
`~/.config/mxrb/credentials` (oder `$XDG_CONFIG_HOME/mxrb/credentials`). MXRB
kopiert oder verändert die referenzierte Datei nicht und liest sie erst für
eine authentifizierte Marketplace-Operation. Neue Scaffolds ignorieren `.env`
und erzeugen eine geheimnisfreie `.env.example`.

`mxrb marketplace login --store-pat` aktiviert die verwaltete Speicherung
explizit; Ziel, JSON-Format und Modus `0600` werden vor der Eingabe angezeigt.
`MXRB_MENDIX_PAT_FILE=/pfad/.env` funktioniert ohne gespeicherte Referenz.
Details zeigt `mxrb marketplace login --help`.

Die offizielle Suche umfasst öffentliche und unternehmensprivate Inhalte.
`show` liefert Herausgeber, Typ, Support, Lizenz, Sichtbarkeit und Freigabe;
`versions` liefert Kompatibilität, Release Notes sowie Sicherheitsstatus und
CVE/CWE-Kennungen.

Mit `--mpr` liest MXRB `package.xml` und die eingebettete `project.mpr` und
importiert den vollständigen Modulbaum direkt über Ruby/SQLite/BSON. Dabei
werden weder `mx` noch `mxcli`, Studio Pro oder das Model SDK ausgeführt. IDs
bleiben erhalten, deklarierte Assets werden transaktional installiert und
Paketcache sowie Modulidentität im Lockfile gespeichert. Kompatible offizielle
Pakete dürfen in eine neuere Modellversion des Projekts importiert werden;
lokale und GitHub-Imports erfordern weiterhin eine identische Modellversion.
Bei Atlas Core werden außerdem die Legacy-Sass-Variablen verbunden, ohne
Projektanpassungen zu überschreiben.

Der offizielle `pull` ist Standard, wählt eine zum Ziel-MPR kompatible Version
und blockiert bekannte verwundbare Versionen ohne `--allow-vulnerable`.
`github:` bleibt als Fallback erhalten, `import` verarbeitet lokale MPKs.
Content ID, Version ID und Sicherheitsstatus werden gesperrt; `audit` prüft
Updates und Schwachstellen. `login` validiert und speichert das PAT außerhalb
des Projekts mit Modus `0600`. Das PAT wird nur an die exakten offiziellen
Hosts `marketplace-api.mendix.com` und `marketplace.mendix.com` gesendet.
