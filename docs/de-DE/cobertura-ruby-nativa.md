# Native Ruby-Abdeckung

Dies ist die verbindliche Matrix für die Erweiterung des Ruby → Mendix-
Compilers. Eine Oberfläche gilt erst dann als `native`, wenn Erstellen, Ändern,
Entfernen, erneutes Öffnen der MPR-Datei und Neukompilieren mit stabilen nativen
IDs getestet sind.

Stand 5. September 2026: Diese konservative Matrix bewertet ganze Familien,
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
| Layouts, Snippets, Building Blocks und Menüs | preserved_native |
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
