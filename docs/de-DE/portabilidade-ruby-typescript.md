# Echte Portabilität zwischen Ruby, TypeScript und Mendix

## Hauptrichtung: Mendix → Ruby + React/TypeScript

Ziel ist ein editierbares Ruby-Backend mit React/TypeScript-Frontend ohne Mendix-
Runtime. Die Rückübersetzung in ein MPR ist ein zusätzlicher Vertrag.
`runtime_only` bedeutet nicht uneditierbar. `portability --require-native` prüft
Ruby → Mendix, nicht die Vollständigkeit der Konvertierung nach Ruby.

Die Ruby-Runtime liest weiterhin eine interne MPR-Kopie für Metadaten und davon
abhängige Graphen. Ohne JVM/Mendix-Runtime bedeutet noch nicht ohne MPR-Baseline.
Nicht übersetzte Varianten, Custom Actions ohne Adapter und nicht unterstützte
Widgets bleiben offene Konvertierungslücken.

Editierbarkeit, Ausdrucksbedingungen, Read-only-Stil, Platzhalter, Passwortmodus,
Maximallänge, ARIA-Label/Pflichtkennzeichnung, Tab-Reihenfolge und Autocomplete
werden als Ruby-Seitenoptionen exportiert. Änderungen in `app/pages/**/*.rb`
wirken ohne MPR-Neukompilierung. Verschachtelte Data Views können eine gesperrte
übergeordnete View nicht entsperren. Unbekannte Bedingungen bleiben gesperrt;
rollenbasierte/native Varianten benötigen noch eine Übersetzung. Backend-
Autorisierung bleibt unabhängig von dieser UI-Steuerung.

Fokus-, Änderungs- und Austrittsaktionen erhalten den Fokus und warten bei Bedarf
auf Schreiboperationen. Serverobjekte werden nicht mehr implizit transient;
Schreibfehler einschließlich 404 bleiben sichtbar. `listen_to` verwendet die
Auswahl des benannten Grids. Mehrstufige Assoziationen enden bei leeren Verweisen,
ohne eine uneingeschränkte Entitätsabfrage auszuführen.

Das Fixture `spec/fixtures/ruby_frontend_editability/project.rb` und das Szenario
`spec/fixtures/frontend_browser/ruby_editability_flow.json` prüfen Editierbarkeit,
Auswahl und Persistenz nach Neuladen in Ruby/React. Komponententests ergänzen
Fokus, Fehlerfälle, Ausdrücke und Assoziationen. Dies bestätigt diesen Ausschnitt,
nicht das gesamte Frontend oder die Unabhängigkeit von jeder Baseline.

Radiogruppen unterstützen Boolean-/Enum-Auswahl, Beschriftungen, horizontale oder
vertikale Anordnung, Tastaturbedienung, Persistenz und Fokus-/Austrittsereignisse.
Geerbte Schreibsperren bleiben erhalten. Unbekannte Werte werden ohne Mutation
angezeigt. Kurze und qualifizierte Enum-Werte werden erkannt; Schreiboperationen
behalten die empfangene Darstellung bei. Enum-Bedingungen unterscheiden weiterhin
verschiedene qualifizierte Typen. Werte und Übersetzungen exportierter Enums stammen
aus Ruby-Definitionen; nicht geladene Legacy-Definitionen verwenden das Manifest.
Nach Quelländerungen die Anwendung neu laden. Neue Dokumente und die Entfernung
des Manifests als Katalog bleiben offen.

Seitentitel verwenden den geladenen Ruby-Titel. Tabs zeigen ein Panel, unterstützen
Pfeile/Home/End und erhalten Eingaben bereits geöffneter Panels; ungeöffnete Panels
werden erst bei Bedarf geladen. Das Fixture `ruby_frontend_core_widgets` und das
Szenario `frontend_browser/ruby_core_widgets_flow.json` prüfen dies einschließlich
Enum-Bedingungen und Persistenz. Nicht projizierte native Tab-Varianten bleiben offen.

MXRB kennzeichnet jedes Artefakt einer Ruby-Anwendung als `native` (editierbares
MPR-Dokument), `preserved_native` (verlustfrei im Mendix-Sidecar erhalten) oder
`runtime_only` (benötigt die MXRB-Runtime).

```bash
bundle exec mxrb portability .
bundle exec mxrb portability . --json
bundle exec mxrb portability . --require-native
```

Der letzte Befehl schlägt fehl, wenn Runtime-only-Code vorhanden ist. Ruby-
Entitäten und Attributregeln werden im Domain Model materialisiert. Unterstützte
Microflow- und Nanoflow-Graphen werden als editierbare `native`-Blöcke exportiert.
Studio-Pro-Seiten müssen `Page.native` verwenden; eine eigene React-Route bleibt
React-Code und wird entsprechend ausgewiesen.

React/TypeScript, das in Mendix laufen soll, wird als offizielles Pluggable Widget
gebaut:

```bash
bundle exec mxrb widgets new OrderSummary widgets-src
bundle exec mxrb widgets build widgets-src/OrderSummary --project "$PROJECT_ROOT"
bundle exec mxrb widgets sync project.rb build/App.mpr
```

Das Browser-Scaffold verwendet ein HttpOnly-/SameSite-Session-Cookie und CSRF-
Token, keinen Bearer-Token in `localStorage`. Unter HTTPS ist
`MXRB_SECURE_COOKIES=true` zu setzen.

Für LazyVim: Abhängigkeiten installieren und `nvim .` öffnen. Nützliche Kürzel
sind `gd`, `gr`, `K`, `<leader>ca`, `<leader>cr`, `<leader>cf` und `<leader>xx`.

Offizielle Referenzen:

- <https://docs.mendix.com/apidocs-mxsdk/apidocs/pluggable-widgets/>
- <https://www.npmjs.com/package/@mendix/generator-widget>
