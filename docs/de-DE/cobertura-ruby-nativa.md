# Native Ruby-Abdeckung

Dies ist die verbindliche Matrix für die Erweiterung des Ruby → Mendix-
Compilers. Eine Oberfläche gilt erst dann als `native`, wenn Erstellen, Ändern,
Entfernen, erneutes Öffnen der MPR-Datei und Neukompilieren mit stabilen nativen
IDs getestet sind.

Stand 27. September 2026: Diese konservative Matrix bewertet ganze Familien,
nicht den prozentualen Fertigstellungsgrad. Für Domäne, Sicherheit und geplante
Ereignisse bestehen inzwischen inkrementelle Bearbeitungswege; nicht
repräsentierte Varianten werden weiterhin erhalten. Geprüfte Verträge und
Grenzen beschreibt die
[Ruby-Round-trip-Prüfung (Portugiesisch)](../reviews/ruby-code-review-2026-09-05.pt-BR.md).

Die Zustände sind `native`, `partial`, `preserved_native` und `runtime_only`.

| Oberfläche | Zustand |
|---|---|
| Entitäten, nicht persistente DTOs und Attribute | native |
| Lokale und modulübergreifende Assoziationen | native |
| Enumerationen | native |
| Konstanten und Zugriffsregeln | partial |
| Indizes, Systemmitglieder, Generalisierung und OQL Views | partial |
| Entity Lifecycle | partial |
| Modulrollen und Projektsicherheit | partial |
| Microflows, Nanoflows und Core Pages | partial |
| Layouts, Page Templates, Snippets und Building Blocks | native |
| Menüs | partial |
| Navigation und Pluggable Widgets | partial |
| Scheduled Events | partial |
| Reguläre Ausdrücke (Mendix/JVM-Text) | native |
| REST, OData, App/Web Services und Mappings | preserved_native |
| Java Custom Actions und externe Connectors | runtime_only |
| Workflows und Task Pages | preserved_native |
| Settings, Themes, Design System und Ressourcen | partial |
| Konventionelles React/TypeScript | runtime_only |

Die Umsetzung erfolgt über vollständige Domain-Unterstützung, Security und
Runtime Settings, Flow-Sprache, UI, Integrationen, Workflows und anschließend
die Zertifizierung je Mendix-Version mit `mxbuild`, Studio Pro und semantischem
Vergleich.

Unbekannte Varianten bleiben fail-closed: Sie werden erhalten und gemeldet,
niemals stillschweigend konvertiert oder verworfen.

## Wiederverwendbare Präsentationsdokumente

`script/presentation_documents_gate` erstellt Layouts, Page Templates, Snippets
und Building Blocks mit der typisierten Forms-DSL, exportiert lesbares Ruby und
kompiliert die MPR über zwei Zyklen neu. Das Gate verlangt strukturelle
Gültigkeit, stabile Dokumentsemantik sowie stabile Unit- und innere Node-IDs.
Mit `--mxbuild` paketiert das offizielle MxBuild 11.12.1 das finale Fixture mit
Exit-Status null und ohne Probleme.

Unterstützte Menüdokumente sind ebenfalls maßgeblich: lokalisierte Captions,
Page- und Microflow-Ziele, Glyph-Icons, rekursive Einträge sowie das Entfernen
von Dokumenten und Einträgen durchlaufen lesbares Ruby mit stabilen kompatiblen
Identitäten. Unbekannte Aktionen oder Icons fallen auf verlustfreies
`deep_structure` zurück; deshalb bleibt die Familie `partial`. Das Menü-Fixture
durchläuft `script/frontend_acceptance` für Quell- und Neuaufbau-MPR mit dem
offiziellen MxBuild 11.12.1 ohne Fehler und ohne strukturelle Unterschiede.

Navigationsprofile stellen moderne und ältere Anwendungstitel, Aktivierungs-
und Offline-Status, rollenbezogene Startseiten, Login-Titel und -Position,
Not-found-Ziele sowie das Partial-Sync-Verhalten bereit. Änderungen behalten
native und verschachtelte Identitäten bei. Nicht dargestellte PWA- und
Offline-Konfigurationen bleiben opak und unverändert; Navigation bleibt daher
`partial`.

## Eigenschaften der Core-Forms

`script/forms_core_project_gate` erzeugt eine Mendix-11.12.1-MPR mit je einem
isolierten Vorkommen aller geerbten Eigenschaften der 41 konkreten
Core-Widgets, exportiert sie als lesbares Ruby, kompiliert sie neu und öffnet
die typisierte MPR erneut. Das Gate zertifiziert 455/455 Eigenschaften als
`imported` und `compiled`; Darstellung, Quellcodeausgabe,
Speichertranskodierung und synthetischer Round-trip sind ebenfalls 455/455.
Eine zweite MPR platziert vollständige Witnesses in Layout-, Template-,
Entitäts-, Datei- und Bildkontexten. Das offizielle MxBuild 11.12.1 paketiert
sie ohne Probleme; die typisierte Inspektion dieses akzeptierten Artefakts
zertifiziert `studio_validated` mit 455/455. Der veraltete
`TemplatePlaceholder` wird aus einem ausdrücklich ausgeschlossenen Template
geladen, weil Studio ihn in auslieferbaren Dokumenten selbst verbietet.

## Enumerationen in Ruby-Anwendungen

`--mode ruby` exportiert Klassen nach `app/enumerations/<module>/`. Generierte
Deklarationen beziehen native IDs aus der privaten Projektbasis. Übersetzungen
werden in einem `value`-Block mit `translation 'de_DE', 'Bereit'` angegeben.
Die bisherigen Optionen `id:` und `captions:` bleiben kompatibel.
`value 'Neu', renamed_from: 'Alt'` benennt einen Wert um;
`remove_value 'Alt'` unterscheidet Entfernen mit anschließendem Einfügen von
einer Umbenennung. Mehrdeutige Änderungen werden abgelehnt statt anhand der
Position zugeordnet. Die Reihenfolge der Deklarationen ist maßgeblich. Eine
referenzierte Enumeration kann nicht entfernt werden; nicht repräsentierte
BSON-Felder und Lokalisierungsstrukturen bleiben beim Zusammenführen erhalten.
