# Native Ruby-Abdeckung

Dies ist die verbindliche Matrix für die Erweiterung des Ruby → Mendix-
Compilers. Eine Oberfläche gilt erst dann als `native`, wenn Erstellen, Ändern,
Entfernen, erneutes Öffnen der MPR-Datei und Neukompilieren mit stabilen nativen
IDs getestet sind.

Stand 28. September 2026: Diese konservative Matrix bewertet ganze Familien,
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
| Published REST und JSON-Mappings | partial |
| Consumed REST und konsumiertes OData | partial |
| Message Definitions und abgeleitete XML-Mappings | partial |
| Published OData | partial |
| App/Web Services | partial |
| XSD/WSDL und weitere Mappings | partial |
| Java Custom Actions | native |
| Externe Connectors | partial |
| Workflows und Task Pages | partial |
| Settings, Themes, Design System und Ressourcen | partial |
| Konventionelles React/TypeScript | runtime_only |

Die Umsetzung erfolgt über vollständige Domain-Unterstützung, Security und
Runtime Settings, Flow-Sprache, UI, Integrationen, Workflows und anschließend
die Zertifizierung je Mendix-Version mit `mxbuild`, Studio Pro und semantischem
Vergleich.

Unbekannte Varianten bleiben fail-closed: Sie werden erhalten und gemeldet,
niemals stillschweigend konvertiert oder verworfen.

## Workflows und Task Pages

`workflow` erstellt Kontext, Namens-/Beschreibungsvorlagen, Fälligkeit,
Start/Ende und einfache menschliche Aufgaben. Eine
`SingleUserTaskActivity` verweist auf eine Task Page, deren erforderlicher
Objektparameter `System.WorkflowUserTask` über die Page-DSL bearbeitbar ist;
XPath-Targeting, `NoEvent` und ein Outcome mit leerem Flow gehören zum Vertrag.
Zwei MPR-→-Ruby-→-MPR-Zyklen erhalten Semantik und alle inneren Workflow-IDs,
und MxBuild 11.12.1 paketiert das Fixture erfolgreich. Alternative Aufgaben,
Targetings, mehrere Outcome-Flows, Timer, Boundary Events, Subprozesse und
erweiterte Sicherheit bleiben im verlustfreien Fallback; daher bleibt die
Familie `partial`.

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

## Published REST und JSON-Mappings

`spec/fixtures/published_rest/project.rb` deklariert einen Service mit
Ressourcen, GET-/POST-Operationen, Path-Parametern, Microflows und
Erfolgsstatus. Der Compiler leitet typisierte JSON-Strukturen und Export-
Mappings für Entity-/Listen-Antworten ab. Zwei Ruby-→-MPR-Zyklen behalten
Unit-IDs bei, erzeugen kein `deep_structure` und bleiben semantisch identisch.
`script/frontend_acceptance` akzeptierte Quell- und Neuaufbauprojekt mit
MxBuild 11.12.1 ohne Fehler und mit `frontend_ready: true`.

Die Familie bleibt `partial`: Nur erkannte Shapes verwenden die semantische
DSL; nicht dargestellte Operationen, Authentifizierungs- oder Mappingvarianten
bleiben im verlustfreien Fallback.

## Consumed REST und konsumiertes OData

`spec/fixtures/consumed_services/project.rb` kombiniert einen REST-GET ohne
Body mit URL-Parametern, geordneten Headern, Timeout und HTTP-Antwortbehandlung
mit einem konsumierten OData-Service auf Basis gültigen CSDL v4 und einer
konstantenbasierten Service-URL. Zwei Ruby-→-MPR-Zyklen behalten Semantik und
Unit-IDs ohne `native_fragment`, `deep_structure` oder opakes BSON in den
zertifizierten Quellen. MxBuild 11.12.1 akzeptiert Quell- und Neuaufbauprojekt
ohne Fehler oder strukturelle Unterschiede und mit `frontend_ready: true`.

Bodylose Aufrufe verwenden das in realen Projekten beobachtete leere
`CustomRequestHandling`. Die DSL weist unvollständige Mapping-Paare und die
Mischung eines eigenen Bodys mit einem Export-Mapping zurück. Die Familie
bleibt `partial`: Form-Data, Authentifizierungs-/Proxyvarianten,
Metadata-Referenzen und validierte OData-Entitäten bleiben bei unbekannten
Shapes im verlustfreien Fallback.

## Message Definitions und abgeleitete XML-Mappings

`spec/fixtures/message_xml/project.rb` deklariert eine Entity und Attribute,
die über eine `MessageDefinitionCollection` veröffentlicht werden, Import-/
Export-Mappings mit `XmlPath` sowie zwei Microflows für XML-Import und -Export.
Zwei Ruby-→-MPR-Zyklen behalten Semantik und Unit-IDs ohne `native_document`,
`deep_structure`, `native_fragment` oder opakes BSON in den zertifizierten
Quellen. MxBuild 11.12.1 akzeptiert Quell- und Neuaufbauprojekt ohne Fehler
oder strukturelle Unterschiede und mit `frontend_ready: true`.

Mappings auf Basis von Message Definitions aktivieren keine Schema-Validierung,
da MxBuild sie XSD-basierten Mappings vorbehält. Die Familie bleibt `partial`:
verschachtelte Bäume, Assoziationen, Konverter, XSD/WSDL und weitere Varianten
bleiben bis zu eigener Evidenz im verlustfreien Fallback.

## App Services und Web Services

Konsumierte App Services stellen jetzt Position, Timeout, App-Store-Metadaten,
Actions, Parameter und Rückgabewerte über `consumed_app_service` bereit.
Veröffentlichte SOAP-Services stellen Versionen, Namespaces,
Authentifizierung, Operationen, skalare Parameter und Microflow-Referenzen über
`published_web_service` bereit. Das Gate führt zwei Ruby-→-MPR-Zyklen aus und
verlangt identischen Vergleich sowie stabile Unit-IDs; auch der ältere
`ConnectorKitDemo`-Korpus exportiert erkannte Shapes über die semantische DSL.

Die Familie bleibt `partial`: eingebettete MSD-Verträge werden verlustfrei
erhalten. Strukturierte SOAP-Entities, Child Members und zukünftige Varianten
bleiben bis zu einem eigenen typisierten Modell im fail-closed Fallback.

## XSD und zugehörige Mappings

`xml_schema` deklariert XSD-Dateien mit Pfad, Inhalt, Target Namespace und
lokalisierten Formaten. Import-/Export-Mappings können über die vorhandene DSL
auf Schema und Root Element verweisen. Zwei Ruby-→-MPR-Zyklen behalten IDs und
semantische Gleichheit; MxBuild 11.12.1 paketiert das vollständige Fixture
einschließlich Import-Mapping ohne Fehler.

Die Implementierung deckt außerdem `imported_web_service` mit rohem
WSDL-Inhalt, eingebetteten Schemas, URL, Target Namespace sowie Import-/MTOM-
Flags ab. Sie verwendet die älteren physischen Namen `ImportedServiceImpl`,
`WsdlDescriptionImpl`, `WsdlEntryImpl`, `SchemaContentss` und
`XmlSchemaContents`, die von den öffentlichen Model-SDK-Namen abweichen. Die
Familie bleibt `partial`, solange bereits geparste WSDL-Services und
-Operationen, komplexe Mapping-Bäume und weitere Varianten noch den
verlustfreien Fallback verwenden.

## Java Custom Actions und externe Connectors

`java_action` materialisiert die native Signatur, Parameter, generische Typen,
Rückgabetyp und visuelle Metadaten. Das Scaffold `mxrb java-action new` erzeugt
zusätzlich die `UserAction`-Klasse unter `javasource/<modul>/actions`; Exporte
kopieren die Quellen und zwei Ruby-→-MPR-Zyklen behalten Inhalt, Semantik und
IDs. Das vollständige Fixture wird mit MxBuild 11.12.1 kompiliert und paketiert.

Marketplace-Connectors bleiben externe Abhängigkeiten: MXRB prüft verifizierte
GUIDs, öffentliche Oberfläche und Provenienz und installiert nur über einen
authentifizierten offiziellen Adapter. Geschützte Module werden nicht als
editierbar dargestellt; nicht aufgelöste Paketanfragen schlagen fail-closed
fehl.

## Published OData

`spec/fixtures/published_odata/project.rb` deklariert einen schreibgeschützten
OData-4-Service mit erlaubter Rolle, Basic-Authentifizierung, Entity Type, ID,
Attributen und einem paginierten Entity Set mit Query-Optionen. Zwei
Ruby-→-MPR-Zyklen behalten Semantik und Unit-IDs ohne `native_document`,
`deep_structure`, `native_fragment` oder opakes BSON in der zertifizierten
Quelle. MxBuild 11.12.1 akzeptiert Quell- und Neuaufbauprojekt ohne Fehler oder
strukturelle Unterschiede und mit `frontend_ready: true`.

Die Service-Position endet gemäß MxBuild-Regel CE6552 mit `/`. Die Familie
bleibt `partial`: Schreibmodi, veröffentlichte Microflows, Enumerationen,
Assoziationen, GraphQL und weitere Varianten bleiben bis zu eigener Evidenz im
verlustfreien Fallback.

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
