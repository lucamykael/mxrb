# Protokoll des Studio-Backends

[Português](../pt-BR/studio-backend.md) · [English](../en-US/studio-backend.md) · **Deutsch**

`mxrb studio serve` betreibt MXRB als Backend einer IDE: ein langlebiger
Prozess, der JSON-RPC 2.0 über stdin und stdout spricht. Jede IDE-Funktion, die
MXRB gehört (Befehlskatalog und Tasks, Dateien des Ruby-Projekts, Konvertierung,
Dokumenteigenschaften, typisierte Modelloperationen mit Rückgängig und
Wiederholen, Ruby/Mendix-Synchronisierung, Schreibkoordination, ER und
Datenbankabfragen), ist eine Methode von `Mxrb::Studio::Service`. Die IDE
zeichnet; MXRB entscheidet und speichert.

```sh
mxrb studio serve [--state-root DIR]
```

Der Zustand (Verknüpfungen von Ruby-Projekten, Synchronisierungsbasen,
Rückgängig-Journale) liegt unter `$XDG_STATE_HOME/mxrb/studio`, sofern
`--state-root` nicht angegeben ist.

## Framing und Sitzung

- Eine JSON-RPC-Nachricht pro Zeile (NDJSON). JSON-Text enthält nie einen
  wörtlichen Zeilenumbruch, daher ist eine Zeile immer eine ganze Nachricht.
- Anfragen laufen nebenläufig; Antworten können in beliebiger Reihenfolge
  eintreffen.
- Die erste Anfrage ist `initialize`. Der Client nennt die Protokollversionen,
  die er spricht, und optional seine Workspace-Wurzeln (für Datei- und
  Zeilenangaben in Fehlern):

```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocol_versions":[2],"roots":["/work/shop-ruby"]}}
```

Die Antwort nennt das Protokoll (`mxrb-studio` 2), die Serverversion, alle
Methoden, die Benachrichtigungen und die Fähigkeiten (Abbruch, Fortschritt,
Fork-Isolation, Rückgängig, Synchronisierung, Sperren). Ein Client ohne
unterstützte Version erhält den Fehler `-32015` mit `data.supported`.

- `shutdown` wartet auf laufende Anfragen und lehnt danach neue ab; die
  Benachrichtigung `exit` beendet den Prozess. Das Schließen von stdin bricht
  ab, was noch läuft.

## Methoden

| Gruppe | Methoden |
|---|---|
| Katalog und Tasks | `catalog/list`, `catalog/arguments`, `tasks/prepare`, `tasks/run`, `tasks/input` |
| Dateien | `files/list`, `files/read`, `files/write`, `files/create`, `files/move`, `files/worktrees` |
| Ruby | `ruby/syntax`, `ruby/declarations` |
| Projekt | `snapshot/create`, `project/status`, `project/convert`, `project/attach` |
| Dokumente | `documents/list`, `documents/read`, `documents/patch` |
| Modell | `model/capabilities`, `model/revision`, `model/preview`, `model/apply`, `model/history`, `model/undo`, `model/redo`, `model/catalog`, `model/domainDiagram` |
| Daten | `data/logical`, `data/physical`, `data/query`, `data/explain` |
| Synchronisierung | `sync/link`, `sync/unlink`, `sync/status`, `sync/run` |
| Sperren | `locks/acquire`, `locks/release`, `locks/status` |

`catalog/list` liefert jeden öffentlichen CLI-Befehl und jedes Scaffold mit
einem typisierten Argumentschema; `tasks/run` führt einen davon als
Kindprozess aus und sendet die Benachrichtigungen `tasks/started` und
`tasks/output`. Das Abbrechen der Anfrage stoppt den Task (`cancelled: true`
im Ergebnis).

`ruby/syntax` parst mit Prism und liefert Diagnosen mit Zeile und Spalte;
`ruby/declarations` listet die Mendix-Artefakte, die eine Datei deklariert
(`entity`, `page`, `microflow`, ...), mit ihren qualifizierten Namen. Keine der
beiden Methoden wertet Ruby aus.

`files/write` und `documents/patch` erhalten die zuletzt gelesene Revision und
schlagen mit einem Konflikt fehl, wenn sich Datei oder Unit inzwischen
geändert haben; beide Fassungen bleiben erhalten.

## Fortschritt, Abbruch und Fehler

- `$/cancelRequest` mit `{"id": ...}` bricht eine Anfrage ab.
- Lange Operationen senden `$/progress`-Benachrichtigungen (`token` =
  Anfrage-ID, `kind` = `begin`/`report`/`end`, `current`, `total`, `detail`).
  Jede MXRB-Operation, die im Terminal Fortschritt zeigt, meldet ihn hier, und
  jede Meldung ist ein Abbruchpunkt.
- Das Auswerten eines Ruby-Projekts und der Export eines Modells laufen in
  einem per Fork gestarteten Kindprozess: Eine Definition, die `exit` aufruft,
  in einer Schleife hängt oder den Speicher erschöpft, legt den Server nicht
  lahm, und ein Abbruch beendet den Kindprozess.

Fehler sind JSON-RPC-Fehlerobjekte mit `data.kind` und, sofern bekannt,
`data.locations` (`file`, `line`, `column`):

| Code | `kind` | Bedeutung |
|---|---|---|
| -32700 / -32600 / -32601 / -32602 | `parse_error` / `invalid_request` / `method_not_found` / `invalid_params` | JSON-RPC-Bedingungen |
| -32002 | `not_initialized` | eine Anfrage vor `initialize` |
| -32800 | `cancelled` | die Anfrage wurde abgebrochen |
| -32010 | `conflict` | das Ziel hat sich seit dem Lesen geändert; nichts wurde überschrieben |
| -32011 | `busy` | ein anderer Prozess schreibt das Modell; erneut versuchen |
| -32012 | `validation` | das Modell oder die Operation ist ungültig |
| -32013 | `toolchain` | ein benötigtes Werkzeug oder ein Systemaufruf ist fehlgeschlagen |
| -32014 | `ruby_source` | Ruby lässt sich nicht parsen oder auswerten; siehe `locations` |
| -32015 | `unsupported_protocol` | keine gemeinsame Protokollversion |
| -32603 | `internal_error` | alles andere |

## Koordiniertes Schreiben

Jeder MXRB-Schreiber eines Modells oder Workspaces nimmt ein exklusives
`flock` auf `$XDG_STATE_HOME/mxrb/studio/locks/<sha256 des kanonischen Pfads>`.
Eine IDE, die dasselbe Modell speichert, nimmt dieselbe Sperre, direkt oder
über `locks/acquire` (der Server hält die Sperre für die Lease bis
`locks/release` oder bis zum Ende der Verbindung). `locks/status` meldet, ob
jemand sie hält. MXRB wartet bis zu 30 Sekunden und antwortet dann `busy`.

## Rückgängig und Wiederholen

`model/apply`, `documents/patch` und `sync/run` schreiben einen
Journaleintrag mit den exakten nativen Bytes jeder Unit, die sie hinzugefügt,
entfernt oder geändert haben. `model/undo` stellt sie Byte für Byte wieder her
(IDs, Referenzen und Layout eingeschlossen); `model/redo` wendet sie erneut
an. Ein Eintrag wird nur rückgängig gemacht, solange seine Units noch den
Zustand haben, den er hinterlassen hat; sonst schlägt die Anfrage mit einem
Konflikt fehl und nichts wird geschrieben. Das Journal behält die letzten 100
Einträge.

## Ruby- und Mendix-Synchronisierung

`sync/link` hält die synchronisierte Basis eines Modells und seines
Ruby-Projekts fest: eine Kopie des Modells, eine Kopie der Ruby-Dateien, den
Ruby-Export des Modells und das aus dem Ruby generierte Modell. `sync/status`
ist günstig: geänderte Ruby-Dateien mit Parse-Diagnosen und deklarierten
Artefakten, geänderte Mendix-Units und ungelöste Konflikte, zusammengefasst als
`synced`, `pending`, `conversion_error` oder `conflict`.

`sync/run` synchronisiert beide Richtungen:

1. **Mendix-Änderungen** sind die Units, deren Bedeutung vom Basismodell
   abweicht. Reihenfolge der Eigenschaften, frisch generierte IDs und die
   Reihenfolge der Entitäten gelten nicht als Änderung.
2. **Ruby-Änderungen** sind die Units, deren Generierung aus dem aktuellen
   Ruby von der Generierung des Basis-Ruby abweicht. Sie werden als
   Elementoperationen (eine Eigenschaft setzen, ein Kind einfügen, entfernen
   oder umordnen) in den IDs des Modells ausgedrückt; ihre Anwendung erhält
   IDs, Referenzen, Layout und jede unberührte Eigenschaft. Das Löschen der
   Ruby-Deklaration eines Dokuments entfernt das Dokument.
3. Ein Element, das beide Seiten geändert haben, ist ein **Konflikt**. Ein
   Lauf mit Konflikten schreibt nichts und liefert jeden Konflikt mit den
   Werten von Basis, Mendix und Ruby (`kind` `element`, `unit` oder `file`).
   Ein erneuter Lauf mit `resolutions` (`{"<Konflikt-ID>": "ruby" | "mendix"}`)
   wendet alles an.
4. Ruby-Änderungen werden in einer einzigen, im Journal erfassten Transaktion
   unter der Schreibsperre auf das Modell angewendet, nur wenn sich das Modell
   während des Laufs nicht geändert hat.
5. Mendix-Änderungen werden mit einem zeilenbasierten Drei-Wege-Merge in die
   Ruby-Dateien übernommen: Kommentare und Ruby-Code außerhalb der geänderten
   Zeilen bleiben unverändert. Eine Änderung auf der einen Seite neben einer
   Einfügung auf der anderen ist kein Konflikt. Überschriebene Dateien werden
   vorher in den Backup-Ordner der Basis kopiert.
6. `.mxrb/` (die native Ausgangsbasis und das Asset-Manifest) gehört MXRB und
   spiegelt immer das synchronisierte Modell.

Ruby, das sich nicht parsen oder auswerten lässt, lässt das Modell unberührt;
der Lauf schlägt mit `ruby_source` und den Fundstellen des Fehlers fehl. Das
letzte gültige Modell bleibt, wie es ist, und die Ruby-Änderungen bleiben
ausstehend.

`sync/status` meldet außerdem `diverged`-Units: Units, bei denen das aus dem
synchronisierten Ruby generierte Modell etwas anderes bedeutet als das Modell
selbst. Sie zeigen, welche Teile eines Modells die Ruby-Projektion noch nicht
erfasst; ihr nativer Inhalt bleibt erhalten, wird aber nicht konvertiert.

Gemessen am öffentlichen Sudoku-Beispiel (409 Units, 355 Ruby-Dateien, Ruby
4.0, ein Kern pro Kindprozess): Verknüpfen 23 s, Ruby nach Mendix 21 s
(bestimmt durch die Generierung des gesamten Projekts aus Ruby), Mendix nach
Ruby 5 s, `sync/status` 0,2 s.

## Einzelaufrufe

`Mxrb::Studio::Backend#call` nimmt ein Anfrageobjekt mit einem
`action`-Namen der Version 1 (`catalog`, `file_read`, `model_apply`, ...)
entgegen und erreicht dieselben Methoden, für Clients, die pro Anfrage einen
Prozess starten.

[Zurück zum Dokumentationsindex](README.md)
