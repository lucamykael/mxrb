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
Design und GitHub-CI. `mxrb page new Modul.Seite` erzeugt weiterhin eine
minimale Seite. Mit `--chain` entsteht ein ausführbarer vertikaler Schnitt mit
Beispielentität, Data-Source-Microflow, editierbarer Seite, Aktionen und
Responsive-Menüeintrag. Drei echte Mendix-Aktionsketten stehen zur Verfügung:

```sh
mxrb page new App.Order --chain page:microflow
mxrb page generate App.Order --chain page:nanoflow
mxrb page g App.Order --chain page:nanoflow:microflow
```

`page:microflow` ruft die Runtime direkt auf; `page:nanoflow` hält die Aktion
auf dem Client; `page:nanoflow:microflow` verwendet den Client-Flow zur
Orchestrierung eines Runtime-Aufrufs. Alle Modi erzeugen `ACT_LoadOrder` als
Data Source. Ketten, die mit einem Microflow enden, erzeugen zusätzlich
`ACT_RefreshOrder`. `page generate` und `page g` sind Aliase von `page new`.
Jede erzeugte Kette wird als gültiges MPR materialisiert und durch den
Compiler-Preflight geprüft.

## Seitenvorlagen

In Mendix sind Page Templates Ausgangspunkte, deren Struktur zu einer normalen,
editierbaren Seite wird. MXRB listet nur durch Compiler und Runtime auditierte
Muster:

```sh
mxrb page templates
mxrb page templates --json
mxrb page new App.Landing --template starter
mxrb page new App.Empty --template blank
mxrb page new App.Operations --template dashboard
mxrb page new App.Order_NewEdit --template form-vertical
```

`form-vertical` erzeugt zusätzlich eine Beispielentität und eine
`ACT_Load...`-DataView-Quelle. Jede Vorlage lässt sich mit `--chain`
kombinieren; `--template dashboard --chain page:nanoflow` ergänzt zum Beispiel
eine Client-Aktion. Diese Namen sind stabile, von Mendix-Mustern inspirierte
MXRB-Verträge; sie behaupten nicht, alle installierten Atlas- oder Marketplace-
Vorlagen still zu importieren. Siehe die [offizielle Seitendokumentation](https://docs.mendix.com/refguide/pages/).

Artefaktbefehle verwenden `new Modul.Name`; Projektbefehle verwenden
`design init` und `ci init github`. Alle unterstützten Entitätstypen und
Assoziationen stehen in der [Entitäten-DSL](entity-dsl.md). Published REST und
Java Action erzeugen editierbare Ruby-Adapter; das native Dokument bzw. die
Aktion muss weiterhin aus einem exportierten Baseline oder Studio Pro stammen.
