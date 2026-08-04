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

## Frontend-Migration und Abnahme

```sh
mxrb frontend migrate App.mpr --json
mxrb frontend migrate App.mpr --apply --json
script/frontend_acceptance App.mpr -o frontend-round-trip.json
script/frontend_acceptance App.mpr --mxbuild /pfad/mxbuild -o frontend.json
script/frontend_acceptance App.mpr --mx /pfad/mx -o frontend-diagnostics.json
```

`mxrb frontend migrate` ist standardmäßig eine unveränderliche, fail-closed
Vorschau. Für Mendix 10 und 11 plant der Befehl Aktualisierungen installierter
Pluggable-Widget-Schemata, alter Layout-Zeilen-Gewichte und Design Properties
aus dem Paket-XML. `--apply` schreibt nur einen sicheren Plan in einer einzigen
MPR-Transaktion. Unbekannte konfigurierte Properties, eine nicht unterstützte
Generation oder eine nach der Vorschau geänderte Unit blockieren den Schreibzugriff.
Weder Vorschau noch Anwendung rufen Mendix-Werkzeuge auf.

`script/frontend_acceptance` ist das reproduzierbare 10/11-Gate. Es validiert
Quell- und Rebuild-MPR, verlangt für beide einen kompatiblen nativen Preflight,
exportiert nach Ruby, baut neu auf, vergleicht die Modellstruktur und prüft
vollständige Asset-Inventare, Bytes, SHA-256-Prüfsummen und Marketplace-
Provenienz. Die Provenienzgrenze umfasst `.mxrb/marketplace.lock.json`, den
Paketcache und `.mxrb/marketplace-originals`; fehlende, geänderte oder
unerwartete Dateien lassen das Gate fehlschlagen. Die akzeptierte Renderer-
Matrix deckt jetzt Forms-Tabellen, `ListViewXPathSource`, Listen-Target-
Objekt-Properties, strukturierte Page-Variable-Mappings und Combo-box-
Enumerationen ab. Die Preflight-Basis sank unter 10.24 von 28 auf 0 und unter
11.12 von 20 auf 0 Befunde.

Ohne `--mxbuild` lautet der Report-Scope `round_trip`, und `frontend_ready`
bleibt unbelegt. Mit `--mxbuild` dient MxBuild als schreibgeschütztes externes
Orakel und der Scope lautet `frontend`; es generiert, verändert oder repariert
das Projekt nie. Das Live-Orakel akzeptiert Erfolg nur, wenn MxBuild mit Status
null endet und ein nicht leeres MDA erzeugt; ein Toolchain-Fehler ohne gemeldete
Modellfehler schlägt geschlossen fehl. Am 4. August 2026 schloss die sichere
Migration die akzeptierte Matrix 10.24.0.73019 und 11.12.1 ab: Quelle und Rebuild lieferten null
MxBuild-Fehler, und beide Reports setzten `frontend_ready` auf `true`.

`--mx` führt den offiziellen schreibgeschützten Checker mit Warnungen,
Deprecations und Best-Practice-Empfehlungen aus. Das Gate validiert die
Exit-Bitmaske und vergleicht normalisierte Signaturen von Quelle und Rebuild.
Die akzeptierte 10.24-Fixture hat 0 Fehler, 173 paketbezogene Warnungen,
0 Deprecations und 2 Kafka-Empfehlungen; 11.12 hat 0 Fehler, 10 paketbezogene
Warnungen, 0 Deprecations und dieselben 2 Empfehlungen. Die JSON-Dateien von
Quelle und Rebuild sind in beiden Generationen bytegleich; diese beobachtbaren
Paketdiagnosen sind kein MXRB-Round-trip-Drift.

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
mxrb marketplace dependencies CommunityCommons --mpr MeineApp.mpr
mxrb marketplace dependencies CommunityCommons --mpr MeineApp.mpr --apply
mxrb marketplace dependencies CommunityCommons --mpr MeineApp.mpr --apply-resolved
mxrb marketplace update 170@3.5.0 --mpr MeineApp.mpr
mxrb marketplace update 170@3.5.0 --mpr MeineApp.mpr --apply
mxrb marketplace remove CommunityCommons --mpr MeineApp.mpr
mxrb marketplace remove CommunityCommons --mpr MeineApp.mpr --apply
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

`marketplace dependencies` entdeckt ungelöste qualifizierte Modulreferenzen im
eingebetteten Paket-MPR, löst sie rekursiv über die offizielle API, lädt jeden
Kandidaten und akzeptiert ihn nur, wenn das MPK selbst die angeforderte
Modulidentität bestätigt. Projekteigene Module erfüllen Referenzen, ohne als
Marketplace-Pakete ausgegeben zu werden. Standard ist eine Vorschau; `--apply`
verlangt einen vollständig sicheren Graphen und installiert Blätter zuerst mit
Rollback. `--apply-resolved` ist die explizite Freigabe für den verifizierten
Teilgraphen und meldet ungelöste Identitäten weiterhin als blockiert.

Am 4. August 2026 importierte die authentifizierte Abnahme Kafka 2.12.0
(Content ID 105878) und löste den offiziellen Graphen unter 10.24.0.73019 und
11.12.1. Beide Graphen importierten DataWidgets 3.11.3 mit Content ID 116540
und Version ID `e7b6d703-8e47-42f4-bb92-934e3601e71b`. Die abschließend
authentifizierte Combo box ist die unabhängige offizielle Widget/clientModule-
Komponente 219304, Version 2.9.0, Version ID
`dce845f4-d051-4161-847c-016c01703caa`. Ihre Installation sichert und ersetzt
das ältere Combo-2.6.x-Asset aus Atlas Core (Content ID 117187); Atlas ist der
frühere Asset-Eigentümer, nicht die Combo-Komponente. Der 11.12-Graph enthält
außerdem Library Logging 1.13.0, Encryption 11.1.1, Mx Model Reflection 9.1.0
und Mendix Feedback Module 5.0.0 (Content ID 205506). Da der Namensindex
`FeedbackModule` nicht liefert, nutzt MXRB die offizielle Content ID nur als
Discovery-Hinweis und prüft weiterhin den internen MPK-Modulnamen.

Beide Generationen bestehen jetzt das vollständige Frontend-Abnahme-Gate mit
null Preflight-Befunden für Quelle und Rebuild, struktureller Gleichwertigkeit,
exakten Assets und Marketplace-Provenienz sowie null MxBuild-Fehlern. Ruby-
Export/Rebuild bewahrt den Marketplace-Lock, gecachte MPKs, Originale,
deklarierte Assets und ihre Prüfsummen; das neu aufgebaute Projekt behält damit
die Paketprovenienz und nicht nur die Widget-Bytes. MxBuild bleibt ausschließlich
externe Validierung und nie eine Implementierungsabhängigkeit von MXRB.

Offizielle Befehle `update` und `remove` sind ohne explizites `--apply` sichere
Vorschauen. Vor einer Änderung vergleicht MXRB Modul und Unit-Anzahl aus dem
Lock mit dem Cache-Paket, durchsucht alle externen Units nach Referenzen auf
wegfallende IDs und verweigert veränderte oder fehlende Paket-Assets. Ein
Update muss die Modul-ID und jede extern referenzierte Unit-ID erhalten. Beim
Anwenden sichert MXRB MPR, v2-`mprcontents`, Lock, Caches, deklarierte Assets und
die Atlas-Variablendatei; jeder Fehler stellt diese gesamte Grenze wieder her.
Gemeinsame Assets werden nicht entfernt, solange ein anderes gesperrtes Paket
sie beansprucht.

## Protokoll-Connector-Audit

`mxrb protocols` ist ein schreibgeschütztes Audit der IoT-, Industrie- und
Messaging-Connectoren, die ein Projekt aus dem Marketplace importiert hat. Es
führt kein Protokoll aus und installiert nichts; es meldet nur die öffentlichen
Metadaten, die das Modell offenlegt.

```sh
mxrb protocols App.mpr
mxrb protocols App.mpr --json
```

Erkannte Connectoren werden mit Modulname, Protokoll und Marketplace-
Komponenten-id aufgeführt; nicht erkannte Marketplace-Module werden separat
gelistet. Die Erkennung erfolgt über eine verifizierte `AppStoreGuid`, sodass
ein Modul mit unbestätigter GUID als nicht erkannt gemeldet und nicht geraten
wird.

Diese Protokoll-Registry ist ein dritter Katalog, getrennt von den
wiederverwendbaren Ruby-Modulen aus `mxrb module` und den offiziellen Paketen
aus `mxrb marketplace`.

Verifizierte öffentliche Komponenten-IDs decken derzeit MQTT, OPC-UA, Kafka,
AMQP und WebSocket ab. Authentifizierte Abfragen der Content API und des
offiziellen Katalogs liefern weiterhin keine Modbus-Komponente; Modbus bleibt
daher unregistriert, bis eine offizielle Komponente oder ein echtes MPR-Fixture
die Identität belegt. Öffentliche IDs dienen der Planung; die Erkennung im MPR
erfordert weiterhin eine verifizierte `AppStoreGuid`.

Der Ruby-Builder kann eine Installation deklarieren, ohne ein leeres Modul oder
eine erfundene GUID zu schreiben:

```ruby
builder.connector :kafka, version: "2.12.0"
plaene = builder.connector_plans(adapter: Mxrb::Protocols.adapter(installer:, api:))
plaene.each { puts _1.changes }
plaene.each(&:apply!) # explizite authentifizierte Marketplace-Operation
```

Ohne Adapter bleibt `connector_plans` eine Vorschau. `build!` schlägt bei noch
offenen Connector-Deklarationen ebenfalls geschlossen fehl; der echte Inhalt
muss zuerst über den offiziellen Adapter in ein MPR installiert werden.
Marketplace-Einträge vom Typ `Module` und `Service` können aufgelöst werden,
während das heruntergeladene MPK zusätzlich die Modul-Paketprüfungen bestehen
muss.
