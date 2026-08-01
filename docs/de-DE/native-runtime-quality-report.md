# Qualitätsbericht für nativen Build und Runtime

Datum: 1. August 2026.

## Bestätigtes Ergebnis

- keine funktionale Stufe ruft `mx`, `mxbuild`, `mxcli`, Studio Pro oder Model SDK auf;
- sauberer 12-Stufen-Build und Web-Generierung bestanden mit 6.10.8 (39 Seiten), 7.5.0 (45), 7.17.0 (66), 9.6.1.29396 (90) und 11.12.1;
- die Round-trip-Matrix bestand mit sechs echten Fixtures von 5.21.4 bis 11.12.1: 1.506 Units, 1.734 Artefakte und 3.388 Referenzen;
- auditierte Compiler-Schemas/Seeds decken 6.x, 7.x, 9.x und 11.x ab. 5.x, 8.x und 10.x schlagen bei nativer Kompilierung geschlossen fehl; Runtime benötigt den exakten Patch;
- Data Grid 1 deckt Datenbank/XPath/Microflow, Suche, Sortierung, Paging, Auswahl und auditierte Buttons ab. Data Grid 2 deckt XPath, Attributspalten und Create ab;
- Webprofile: Dojo in 6/7, Dojo/React-Hybrid in 9 und React in 11;
- Projects API inventarisierte 130 Apps. Drei echte Git-Projekte (`MyFirstModule`, `LearnNow Trainning Management`, `SLATaskApp`) bestanden validate → export → generate → validate → compare;
- `MyFirstModule` wurde ohne proprietäre Builder als exaktes 11.12.1 erzeugt. Runtime synchronisierte 655 Operationen, erstellte den aktiven Admin `mx`, lieferte React-Shell und gestaltetes Login auf `127.0.0.1:18080` und zeigte die erwarteten Tabellen;
- finale QA: 813 Beispiele, null Fehler, 100% Zeilen (12.777/12.777), 100% Branches (4.520/4.520) und RuboCop ohne Verstöße in 205 Dateien.

## Korrekturen aus dem Verbesserungsbericht

- selektive Java-Proxy-Erzeugung für verwendete Entitäten, Vererbung, Enums und Konstanten;
- Absenkung der offiziellen Database-Connector-Build-Erweiterung auf External-Database-Connector-Java-Actions, einschließlich sicherem Query-Builder-`SELECT`;
- OQL-Quellen, geerbte Persistenzflags, Demo-User-Rollen, Systemtexte und exakte Association-Storage/Access-Rechte;
- stabile PostgreSQL-Bereitschaft, öffentliche Loopback-Portoption (`--runtime-port`), Admin-Passwort aus Umgebung und Admin-Erstellung;
- eigenständige Login-Ressourcen, gerenderte Platzhalter, Cache-Busting, Stil und i18n;
- Schutz vor Traversal, unsicheren Bezeichnern und Symlinks in nativen Eingaben;
- Vergleich normalisiert fehlende boolesche Runtime-Defaults und erhält exakte Legacy-Round-trips.

## Explizite Grenzen

1. Andere Dojo-Widgets als Data Grid 1 bleiben in `web/mxrb-legacy-pages.json`; sie werden nicht als gerendert gemeldet.
2. Data Grid 2 deckt den auditierten XPath/Attribut/Create-Teil ab; andere Quellen, Filter und Aktionen schlagen geschlossen fehl.
3. Installierte 6/7/9-Distributionen enthalten exakte Bundles, aber keinen kompatiblen PAD/Launcher. Der 11-Launcher benötigt Java 21 und kann 9 unter Java 11 nicht sicher starten. Legacy-`db up` schlägt geschlossen fehl; nur der exakte 11.12.1-Boot wird behauptet.
4. Runtime verwendet eine lokale Trial-/Developer-Lizenz mit erwarteter Zeitlimit-Warnung.
5. Cloud Build/Deploy/Pipelines/Backups sind optionale externe Prüfungen, nie Abhängigkeiten des nativen Kerns.

Es gibt keinen versteckten `mx`/`mxbuild`-Fallback.
