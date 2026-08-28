# Native Ruby-Abdeckung

Dies ist die verbindliche Matrix für die Erweiterung des Ruby → Mendix-
Compilers. Eine Oberfläche gilt erst dann als `native`, wenn Erstellen, Ändern,
Entfernen, erneutes Öffnen der MPR-Datei und Neukompilieren mit stabilen nativen
IDs getestet sind.

Die Zustände sind `native`, `partial`, `preserved_native` und `runtime_only`.

| Oberfläche | Zustand |
|---|---|
| Entitäten, nicht persistente DTOs und Attribute | native |
| Lokale und modulübergreifende Assoziationen | native |
| Enumerationen, Konstanten und Zugriffsregeln | preserved_native |
| Indizes, Systemmitglieder, Generalisierung und OQL Views | preserved_native |
| Entity Lifecycle | partial |
| Modulrollen und Projektsicherheit | preserved_native |
| Microflows, Nanoflows und Core Pages | partial |
| Layouts, Snippets, Building Blocks und Menüs | preserved_native |
| Navigation und Pluggable Widgets | partial |
| Scheduled Events | preserved_native |
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
