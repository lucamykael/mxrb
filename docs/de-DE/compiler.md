# Compiler und MDA-Format

`mxrb pack App.mpr --output build/App.mda` schreibt ein deterministisches
MDA-ZIP vollständig in Ruby. `mxrb mda inspect` inventarisiert das Archiv und
`mxrb mda compare` vergleicht Einträge anhand ihres Inhalts.

Diese erste Stufe benötigt ein bereits materialisiertes `deployment/` mit
`model/model.mdp`, `model/metadata.json`, `model/bundles/project.jar` und
`web/index.html`. Es gibt keinen impliziten Fallback auf `mx`, `mxbuild`, Studio
Pro oder das Model SDK. Archiviert werden nur `model`, `web`, `native`, `sass`
und `tmp`; Arbeitsverzeichnisse von Runtime und Gradle bleiben außen vor.

Adapter unterstützen derzeit Mendix 9.x, 10.x und 11.x. Die native Erzeugung
von Domänenmetadaten, Microflows, Frontend-Bundles, Java-Artefakten und der
portablen Runtime bleibt als Folgestufe explizit offen. Das von MXRB geschriebene
VetClinic-MDA wurde von Runtime 11.12.1 akzeptiert, synchronisierte 675
Datenbankoperationen und lieferte HTTP 200.

`mxrb portable App.mpr --output build/runtime.zip` kombiniert die installierte
versionsgleiche Runtime, generierte Konfiguration und Konstanten sowie das
materialisierte Deployment ohne Aufruf von `mx` oder `mxbuild`. Das
VetClinic-Paket enthielt 4.384 Dateien, synchronisierte 675 Datenbankoperationen
und lieferte HTTP 200. Strukturelle Funktionstests verwenden jetzt
`Mxrb.validate`; die Instrumentierung benötigt weiterhin die native
Materialisierung geänderter Microflows, bevor auch ihr Build `mxbuild` ablösen
kann.
