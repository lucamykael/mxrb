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
