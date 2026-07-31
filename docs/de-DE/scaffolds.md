# Projekt-Scaffolds

[Português](../pt-BR/scaffolds.md) · [English](../en-US/scaffolds.md) · **Deutsch**

Alle Befehle akzeptieren `--target DIR`, überschreiben keine Dateien und
verbinden `evaluate`/`evaluate_dir`-Aggregatoren automatisch. Mit
`mxrb <Befehl> --help` werden Verwendung, Ziel und Optionen angezeigt.

Verfügbar sind Projekt/Modul (`init`, `module new`), Domäne (`entity`,
`enumeration`, `constant`), Anwendung (`use-case`, `validation`, `query`,
`repository`, `scheduled-event`), Präsentation (`presentation init`, `page`,
`nanoflow`), Sicherheit, Infrastruktur (`integration`, `published-rest`,
`consumed-rest`, `java-action`), Prüfung (`functional-test`, `evaluation`),
Design und GitHub-CI.

Artefaktbefehle verwenden `new Modul.Name`; Projektbefehle verwenden
`design init` und `ci init github`. Alle unterstützten Entitätstypen und
Assoziationen stehen in der [Entitäten-DSL](entity-dsl.md). Published REST und
Java Action erzeugen editierbare Ruby-Adapter; das native Dokument bzw. die
Aktion muss weiterhin aus einem exportierten Baseline oder Studio Pro stammen.
