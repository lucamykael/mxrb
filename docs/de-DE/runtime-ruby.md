# Runtime ohne Java

## Modbus TCP und RTU

`Mxrb::Modbus::Client` ist ein eigener Connector für das Ruby-Backend mit den
Funktionen 01/02/03/04/05/06/15/16 der
[Modbus-Spezifikation](https://www.modbus.org/modbus-specifications).
Er ist kein offizielles Marketplace-Paket und erzeugt keinen Mendix-Java-Code.
Der gleiche Client akzeptiert `transport: :tcp` (Standard) oder `transport: :rtu`.
TLS und die Umwandlung von Registern in Gleitkommazahlen sind nicht enthalten.

```ruby
client = Mxrb::Modbus::Client.new(host: ENV.fetch('MODBUS_HOST'), unit_id: 1, timeout: 5)
client.read_holding_registers(0, 2)       # => [4660, 65535]
client.read_coils(0, 8)                  # => Array mit true/false
client.write_single_register(10, 42)     # => 42
client.write_multiple_coils(0, [true, false]) # => 2
```

Weitere Methoden sind `read_discrete_inputs`, `read_input_registers`,
`write_single_coil` und `write_multiple_registers`. Adressen beginnen bei null:
Holding-Register 40001 entspricht Adresse 0. Register sind vorzeichenlose
Ganzzahlen von 0 bis 65535; Coils verlangen boolesche Werte. Lesen liefert Arrays,
einzelnes Schreiben den Wert und mehrfaches Schreiben die bestätigte Anzahl.
Standardport ist 502; `unit_id` akzeptiert 0–255, auch für Gateways.

Bei TCP öffnet und schließt jede Operation ihre Verbindung. Ein gemeinsames Zeitlimit in
Sekunden gilt für Namensauflösung/Verbindung, Senden und Empfang. Automatische
Wiederholungen gibt es nicht: Nach einem Schreib-Timeout ist das entfernte Ergebnis
unbekannt. `ExceptionResponse` enthält `function` und `code`; `ProtocolError`
kennzeichnet ungültige Antworten, `TransportError` (einschließlich `TimeoutError`)
Kommunikationsfehler. Modbus TCP bietet keine Authentifizierung oder Verschlüsselung;
der Endpunkt wird von der Anwendung in einem vertrauenswürdigen Netzwerk konfiguriert.

Ein mit `Registry.register_java_custom_action('Industrial.ReadRegister')` in
`config/adapters.rb` registrierter Adapter kann
`client.read_holding_registers(0).first` zurückgeben. Der Ruby-Microflow-Interpreter
verarbeitet das Ergebnis; der Adapter wird nicht als Java exportiert.

### Lokale TCP-Simulation

Start: `bundle exec ruby examples/modbus_tcp_simulator.rb` im MXRB-Verzeichnis.
Der Simulator lauscht nur auf `127.0.0.1:1502`, mit `unit_id: 1` und Adressen
0–255 je Bereich. Ein numerisches Argument ändert den Port. Coils und Holding-
Register beginnen bei null und behalten Schreibwerte bis zum Beenden; Eingang 0
ist `true`, Input-Register 0 enthält `1234`.

In einem weiteren Ruby-Prozess nach `require 'mxrb'`:

```ruby
client = Mxrb::Modbus::Client.new(transport: :tcp, host: '127.0.0.1', port: 1502)
client.write_multiple_registers(0, [42, 123])
p client.read_holding_registers(0, 2) # [42, 123]
```

Der Simulator ist ein Entwicklungswerkzeug mit Daten im Arbeitsspeicher.
Ctrl+C beendet ihn.

Den vollständigen Anwendungsablauf startet
`bundle exec ruby examples/modbus_application.rb`. Das Beispiel startet einen
eigenen Simulator auf einem freien Port, erzeugt und validiert ein MPR mit der
Entität `Measurement` und dem Microflow `Industrial.ConfigureAndSample`, schreibt
die Sollwerte 42 und 84 und speichert die Messwerte in SQLite. Nach erneutem
Öffnen der Datenbank werden beide Messungen geprüft. Das JSON-Ergebnis enthält
die Pfade zu Modell und Datenbank in einem temporären Verzeichnis, das zur
Inspektion erhalten bleibt. Der Simulator wird automatisch beendet.

### Serielle RTU-Schnittstelle

RTU verwendet ein bereits geöffnetes, von Anwendung/System konfiguriertes serielles
IO im Raw-Modus: 8E1, 8O1 oder 8N2, ohne lokales Echo. Der Adapter übernimmt die
RS-485-Richtungssteuerung. `baud_rate` beschreibt die konfigurierte Geschwindigkeit
für die Zeitberechnung und ändert keine Portparameter. Eine bestimmte serielle
Bibliothek ist nicht erforderlich. POSIX-Beispiel für einen konfigurierten Port:

```ruby
File.open('/dev/ttyUSB0', File::RDWR | File::NONBLOCK | File::NOCTTY) do |serial|
  client = Mxrb::Modbus::Client.new(transport: :rtu, io: serial, baud_rate: 9600, unit_id: 1)
  p client.read_holding_registers(0, 2)
end
```

RTU verlangt `unit_id` 1–247; Broadcast wird nicht unterstützt. Pro Bus darf nur
ein Client verwendet werden; gleichzeitige Aufrufe werden bis zum Abschluss der
Antwortvalidierung abgewiesen. Die Anwendung besitzt und schließt das IO. CRC,
Länge, Adresse und Funktion werden geprüft, ebenso softwareseitig beobachtete
Frame-Abstände und Zeichenpausen. Transport-/Protokollfehler sperren die Sitzung:
Port erneut öffnen und resynchronisieren, bevor ein neuer Client erstellt wird;
unsichere Schreibvorgänge nicht automatisch wiederholen. Eine gültige Geräteausnahme
sperrt die Sitzung nicht. Tests verwenden Pseudo-Terminals und lokales TCP;
elektrische Zeitbedingungen, USB-Treiber und reale Geräte sind noch zu validieren.

## Backend-Ausführung

Der Ruby-Modus startet das Backend ohne Mendix Java Runtime. Beim Öffnen einer
exportierten Anwendung migriert MXRB automatisch eine umgebungsspezifische
SQLite-Datenbank, öffnet den Microflow-Interpreter, registriert Lifecycle-Hooks,
erzwingt die Sicherheit und startet Scheduled Events.

Wie die Runtime führt der Server den After-Startup-Microflow der Model Settings
einmal ohne Benutzer vor den Scheduled Events aus; liefert er nicht `true` oder
schlägt fehl (etwa an einer Java-Action ohne Adapter), startet die Anwendung nicht.
`MXRB_AFTER_STARTUP=skip` startet während einer Migration ohne ihn. Der
Before-Shutdown-Microflow läuft beim Schließen der Anwendung; seine Fehler werden
nur gemeldet.

Profile liegen unter `config/environments/`, typischerweise als
`development.env`, `qa.env`, `staging.env` und `production.env`. Die Priorität
lautet Prozessumgebung, Profildatei, `.env.<Profil>`, dann `.env`. Die Auswahl
erfolgt mit `--environment qa` oder `MXRB_ENV=qa`; `mxrb env . --environment qa`
zeigt Quellen und Schlüsselnamen, niemals Werte.

```bash
mxrb run . --environment qa
mxrb test App.mpr smoke.rb --native --environment qa
```

Während `mxrb run` interpretiert das Backend die Ruby-Quellen und prüft an jeder
Request-Grenze auf Änderungen; für das Frontend bleibt Vite-HMR zuständig. Ein
erfolgreicher Reload tauscht Registry und Runtime unter einem gemeinsamen Lock.
Bei Syntaxfehlern, ungültigen Deklarationen oder unsicheren Migrationen arbeitet
die letzte gültige Revision weiter und `/api/health` meldet den Reload-Fehler.
Mit `--no-reload` wird der Prozess auf eine Quellrevision festgelegt.

Dieser Entwicklungszyklus schreibt keine `.mpr`-Datei und startet MxBuild
nicht. Die `.mpr` wird ausschließlich an der expliziten Grenze `mxrb export`
synchronisiert; native Artefakte ohne Ruby-Implementierung laufen bis dahin im
Interpreter auf Basis des exportierten Mendix-Snapshots.

Jedes Profil verwendet standardmäßig `.mxrb/runtime/<Umgebung>.sqlite3`. Die
Migration leitet Entitäten, Attribute, Assoziationen und System-Member ab.
Additive Änderungen sind idempotent, inkompatible Änderungen verwenden einen
transaktionalen Rebuild. Nicht persistente Entitäten bleiben im Speicher.

Die Ruby-API bietet Login und Bearer-Token, Sessions, Schema, Navigation,
Seiten, Microflows, CRUD und Published REST. Rollen, Entitätsregeln,
Member-Rechte werden für jede Anfrage geprüft. Constraints der Zugriffsregeln
nutzen dieselbe XPath-Engine wie Retrieves (Assoziationen, Funktionen und Tokens
in Anführungszeichen wie `'[%CurrentUser%]'`); eine nicht auswertbare Constraint
verweigert den Zugriff.
Zugangsdaten stammen aus `MXRB_USERS_JSON` und `MXRB_AUTH_TOKENS` und gehören in
ignorierte lokale Dateien oder den Secret Manager des Deployments.

Scheduled Events laufen im stdlib-basierten MXRB-Scheduler mit Minuten-,
Stunden- und Tagesintervallen, Overlap-Schutz und kontrolliertem Shutdown.
IANA-Zeitzonen wie `Europe/Berlin` verwenden `tzinfo` und berücksichtigen
Sommerzeitwechsel. Unbekannte Zonen führen zu einem Fehler statt unbemerkt auf
UTC zurückzufallen; `UTC`, `local` und numerische Offsets werden ebenfalls
unterstützt.

Jede Anfrage läuft in der Zeitzone ihrer Sitzung: der `System.TimeZone` des
Benutzers, falls gesetzt, sonst die IANA-Zone, die der Browser in
`X-Mxrb-Time-Zone` sendet, sonst UTC; `/api/session` meldet sie. Die
`System.TimeZone`-Objekte der Runtime entstehen beim Start, und neue Benutzer
erhalten die Standardzeitzone des Projekts wie in Studio Pro.

Sitzungen und Scheduler-Koordination verwenden standardmäßig die native
SQLite-Datei `.mxrb/runtime/<Umgebung>-shared.sqlite3`, ohne externen Dienst.
Mehrere Instanzen müssen mit `MXRB_SHARED_STORE_PATH` dieselbe Datei verwenden.
Idempotente Claims pro Ereignis/Zeitfenster und per Heartbeat erneuerte
Overlap-Leases sind atomar; ein unvollständiger Claim kann nach Lease-Ablauf
übernommen werden. Der Standard-Lease beträgt 300 Sekunden und lässt sich über
`MXRB_SCHEDULER_LEASE_TTL` ändern. `:memory:`, `memory` oder `local` aktivieren
explizit den prozesslokalen Modus.

Standardmäßig starten Java Custom Actions keine JVM. Jede erlaubte Action
benötigt einen expliziten Ruby-Adapter, der in `config/adapters.rb` unter dem
qualifizierten Namen registriert wird:

```ruby
Mxrb::RubyApp::Registry.register_java_custom_action('Orders.CalculateTotal') do |arguments|
  Calculator.call(
    items: arguments.fetch('Items'),
    discount: arguments.fetch('Discount')
  )
end
```

Die Schlüssel sind die Parameternamen aus dem Mendix-Modell. Basiswerte werden
im Microflow-Kontext ausgewertet; Entity-, Microflow- und Mapping-Referenzen
werden als qualifizierte Namen übergeben. Der Rückgabewert wird nur bei aktivem
`UseReturnVariable` zugewiesen (oder beim Legacy-Format, das ausschließlich
`ResultVariableName` deklariert). Eine nicht registrierte Action schlägt mit
ihrem Namen und einem Registrierungshinweis geschlossen fehl; ohne den unten
beschriebenen optionalen Sidecar gibt es weder Klassenerkennung noch
JAR-Ausführung oder JVM-Fallback. REST, App Services, SOAP,
Mappings und Dokumenterzeugung verwenden weiterhin typbezogene Ruby-Adapter.
Im Browser bleibt JavaScript/React; Backend und APIs laufen ohne Java Runtime.

### Verifizierte Actions und der Microflow-Kontext

Actions von Marketplace-Modulen, deren Quellen MXRB geprüft hat, erhalten
fertige Ruby-Adapter. Der Export vergleicht den SHA-256 jeder Action und der
Hilfsklassen, die sie aufruft, mit den geprüften Releases und schreibt die
Registrierungen nach `config/verified_adapters.rb`. Diese Datei wird bei jedem
Export neu erzeugt und nicht in das MPR eingebettet, sodass ein Round Trip später
geprüfte Actions übernimmt. Sie wird vor `config/adapters.rb` geladen; eine
Registrierung dort ersetzt die verifizierte gleichen Namens.

CommunityCommons hat 19 geprüfte Actions in den Releases 9.0.1 und 11.5.1,
einschließlich ihrer Unterschiede: `Base64Encode`, `EndTransaction`,
`GetApplicationUrl`, `GetModelVersion`, `GetRuntimeVersion`, `Hash`,
`RandomHash`, `RandomString`, `RandomStrongPassword`, `StringFromFile`,
`StringLeftPad`, `StringSplit`, `StringTrim`, `ThrowException`,
`TimeMeasureStart`, `TimeMeasureEnd`, `copyAttributes`,
`executeUnverifiedMicroflowAsUser_2` und `objectHasChanged`. Aus Encryption
verschlüsseln `EncryptString` und `DecryptString` (Releases 8.0.2 und 10.0.2)
`{AES3}` mit AES/GCM und entschlüsseln auch das ältere `{AES}` (AES/CBC),
austauschbar mit dem Java-Code; `{AES2}` scheitert wie auf einer frisch gestarteten
11.12.1-Runtime, der die Cipher `AES/GCM/PKCS5PADDING` fehlt. Die PGP-Actions haben
keinen Adapter. Beim Start folgen `UnitTesting.IsEnabled`, `Initialize`,
`IsInitialized` und `RegisterModelUpdateSubscriber` (10.0.4) der Konstante
`UnitTesting.Enabled`, und `OIDC.DeleteExpiredAuthAttempts` (3.3.1) löscht abgelaufene
Versuche. `MxModelReflection.SyncObjects` (6.2.0 und 8.0.2) portiert den Builder des
Moduls auf das Metamodell der Anwendung, das wiedergibt, was die 11.12.1-Runtime meldet
(`spec/fixtures/native_metamodel`); das System-Modul stammt aus dieser Runtime, auch bei
Projekten anderer Versionen.

Ein Adapter, der den aufrufenden Microflow braucht, verwendet `with_context: true`
und erhält `context:` mit Store, Log, anderen Microflows (auch als anderer
Benutzer oder im Sudo-Kontext), dem Transaktionsende, dem Änderungszustand von
Objekten, Dateiinhalten und der Anwendungs-URL (`MXRB_APPLICATION_ROOT_URL`,
sonst die Adresse des Ruby-Servers). Java-Exceptions sind
`Mxrb::Runtime::JavaActionError` mit dem Namen der Java-Klasse. Gemessen auf der
11.12.1-Runtime und von der Ruby-App reproduziert
(`spec/fixtures/native_java_action_runtime`):

- `$latestError/ErrorType` ist der qualifizierte Java-Klassenname,
  `$latestError/Message` die Exception-Meldung;
- `isChanged` markiert ein Objekt, sobald ein Member gesetzt wird, auch auf den
  bisherigen Wert, bis zum nächsten Commit; ein neues Objekt ohne gesetzte Werte
  ist unverändert;
- `IContext.endTransaction` bestätigt die Transaktion, außer in einem
  Sub-Microflow, der mit benutzerdefinierter Fehlerbehandlung aufgerufen wird und
  dessen Savepoint sie offen hält; danach wird jeder Commit sofort wirksam;
- `Core.getModelVersion` ist außerhalb eines Deployments `unversioned`
  (`MXRB_MODEL_VERSION` setzt einen anderen Wert);
- bei benutzerdefinierter Fehlerbehandlung wird ein fehlgeschlagener
  Sub-Microflow-Aufruf bis zu seinem Savepoint zurückgenommen (ohne Rollback) oder
  nimmt die ganze Transaktion zurück (mit Rollback, `rescue_all(rollback: true)`),
  und der Fehlerfluss läuft weiter, im zweiten Fall in einer neuen Transaktion;
  eine fehlgeschlagene Java-Action behält ihre Commits, und nach dem Ende der
  Transaktion läuft der behandelte Aufruf in einer eigenen Transaktion
  (`spec/fixtures/native_error_handling_transactions`).

### Optionaler Sidecar für das Java des Projekts

Ruby-Adapter bleiben auf die oben geprüften Marketplace-Module beschränkt. Das
eigene Java des Projekts und das noch nicht geprüfter Module kann im Sidecar aus
`docker/java-actions` laufen: einem getrennten Java-Prozess (einem Container), der
nur genutzt wird, wenn `MXRB_JAVA_ACTIONS_URL` auf ihn zeigt (`tcp://host:port`).
Ohne diese Variable ändert sich nichts: eine Action ohne Adapter schlägt
geschlossen fehl. Actions werden in dieser Reihenfolge aufgelöst: Adapter aus
`config/adapters.rb`, verifizierter Adapter, Plattform-Action, Sidecar und zuletzt
der Fehler.

Der Sidecar kompiliert `javasource` und `userlib` des Projekts gegen eine eigene
API mit den Teilen von `com.mendix.*`, die Actions nutzen. Der Sidecar enthält kein
Mendix-Jar. Die API umfasst:

- `IContext`, `ISession`, `UserAction`/`CustomJavaAction`, `ILogNode` und
  `FeedbackHelper`, dessen Meldung zum Show-Message des aufrufenden Microflows wird;
- `IMendixObject` und `IMendixIdentifier`, einschließlich `getMembers`, der Member
  `MendixString`, `MendixInteger`, `MendixEnum`, `MendixObjectReference` usw.,
  `getState`, `isNew` und `getOriginalValue`, verglichen mit dem letzten Commit;
- die Metadaten (`IMetaObject`, `IMetaPrimitive`, `IMetaAssociation`,
  `IMetaEnumeration`, `IDataType`) aus dem Metamodell der Anwendung;
- in `Core`: die XPath-Abfragen (`createXPathQuery`, `retrieveXPathQuery`,
  `retrieveXPathQueryAggregate`, `retrieveByPath`, `retrieveId`), `instantiate`,
  `commit`, `delete`, `rollback`, `microflowCall`, Konfiguration, Konstanten,
  Versionen (auch `RuntimeVersion`), `getMetaObject(s)`, `getInputParameters`,
  `getReturnType`, `createDataType`, `getInternationalizedString` und Inhalte von
  File Documents (`getFileDocumentContent`, `storeFileDocumentContent`);
- tabellarisches OQL (`retrieveOQLDataTable`, `createOQLTextGetRequest`,
  `createOQLTextGetRequestFromDataSet`, `IDataTable`, `IDataRow`, `IParameterMap`),
  ausgeführt von der OQL-Engine der Ruby-Anwendung; eine ID-Spalte enthält den
  Identifier des Objekts;
- Request Handler: `Core.addRequestHandler` registriert den Pfad, und der Server
  der Ruby-Anwendung leitet dessen Anfragen (außerhalb von `/api`, ohne
  CSRF-Token) an den `RequestHandler` weiter, mit
  `IMxRuntimeRequest`/`IMxRuntimeResponse` und der Sitzung des Cookies
  `mxrb_session`; `Core.initializeGuestSession` öffnet eine Gastsitzung, wenn die
  Sicherheit des Projekts Gäste zulässt, und ihre ID ist der Wert des Cookies;
- `IMendixIdentifier.toLong` und `Core.createMendixIdentifier`, mit der in der
  Datenbank der Anwendung gespeicherten Nummer; `Core.getDefaultLanguage`,
  `Core.initializeSession` (mit ihren Kontexten aufgerufene Microflows laufen als
  dieser Benutzer), `Core.executeAsync` (der Sidecar führt den Microflow aus, bevor
  er antwortet) und von der Action gestartete Transaktionen, verschachtelt in die
  des aufrufenden Microflows.

Generierte Proxies haben auch `load(context, xpath)`, wie die von Studio Pro. Das
von Mendix als `com.mendix.thirdparty.org.json` gebündelte `org.json`
(`JSONObject`, `JSONArray`, `JSONException`) hat eine eigene Implementierung im
Sidecar, und `IContext.getRuntimeRequest`/`getRuntimeResponse` sind leer, da die
Ruby-Anwendung die HTTP-Anfrage nicht an Actions weitergibt.

Arbeit, die eine Action nach ihrer Rückkehr weiterlaufen lässt, etwa ein Listener
für MQTT-Nachrichten, der einen Microflow aufruft, läuft ebenfalls über die
Ruby-Anwendung: beim Start der Runtime öffnet sie eine Listen-Verbindung zum
Sidecar, und für jeden Callback dieser Arbeit bittet der Sidecar darüber um eine
eigene Verbindung, die in einer neuen Transaktion mit Systemkontext bedient wird.
Die Verbindung geht immer von der Ruby-Anwendung aus, die also keine Verbindung
aus dem Container annehmen muss. Die Objekte eines Callbacks gelten nur in ihm.

Eine Quelle, die eine andere API nutzt, kompiliert nicht und bleibt draußen, mit
ihrem ersten Fehler in `build-report.tsv`; der Aufruf dieser Action meldet einen
Fehler mit diesem Grund. Enumerationsbeschriftungen folgen den Übersetzungen der
Ruby-Anwendung; die von Studio Pro erzeugten Proxies nutzen die Text-ID jeder
Beschriftung, und das Paket hält in `captions.tsv` fest, welchen Wert jede ID
beschriftet.

Die Ruby-Anwendung bleibt die Runtime. Jeder Aufruf öffnet eine Verbindung mit
JSON-Nachrichten, eine pro Zeile. Die Java-Seite erhält Handles auf die Objekte
des Microflows und liest, ändert, committet, fragt ab und ruft Microflows über
Callbacks auf; Transaktion, Events, Entity-Zugriff und Log bleiben in Ruby. Ein
von Java aufgerufener Microflow darf eine weitere Java-Action aufrufen, die auf
einer eigenen Verbindung läuft. Integer-Attribute kommen als `java.lang.Integer`
an, leere Reference Sets als leere Liste, und die Exception einer Action wird zu
`$latestError` mit ihrer Java-Klasse. `MXRB_JAVA_ACTIONS_TOKEN` authentifiziert die
Aufrufe, wenn es auf beiden Seiten gesetzt ist; `MXRB_JAVA_ACTIONS_TIMEOUT`
(standardmäßig 300 s) begrenzt die Wartezeit je Nachricht. Der Fall
`spec/fixtures/java_action_sidecar` kompiliert echte Actions und führt sie gegen
die Ruby-Anwendung aus.

`mxrb java-actions App.mpr app-ruby` bereitet den Sidecar einer exportierten
Anwendung vor, ohne den Export zu ändern, der weiterhin keine Java-Datei enthält.
Der Befehl schreibt nach `java-actions/` Dockerfile und Quellen des Sidecars, eine
Kopie des `javasource` des Projekts (Quellen, die nicht UTF-8 sind, werden als
ISO-8859-1 gelesen) mit den Proxies, die Studio Pro erzeugen würde und Projekte
nicht versionieren, und die Jars aus `userlib` und `vendorlib`. Außerdem legt er, falls noch keine
existiert, eine `docker-compose.yml` mit dem Dienst `java-actions` auf
`127.0.0.1:7911` an. Das Verzeichnis wird bei jedem Lauf neu geschrieben und nicht
in das MPR eingebettet:

```sh
mxrb java-actions App.mpr app-ruby
cd app-ruby && docker compose up -d java-actions
```

Die URL gehört in das Umgebungsprofil der Anwendung:

```sh
# config/environments/development.env
MXRB_JAVA_ACTIONS_URL=tcp://127.0.0.1:7911
```

## Ruby → Mendix → Ruby-Zertifizierung

Das reproduzierbare Zertifizierungsszenario befindet sich in
[`spec/fixtures/flymetothemoon/project.rb`](../../spec/fixtures/flymetothemoon/project.rb).
Es modelliert Kunden, Produkte, Bestellungen und Positionen in Ruby, inklusive
Enumeration, Indizes, Assoziationen, Microflows, Nanoflow, Scheduled Event und
einer Seite mit Data Grid. Der Test
[`spec/flymetothemoon_roundtrip_spec.rb`](../../spec/flymetothemoon_roundtrip_spec.rb)
prüft folgende Anwendungsfälle:

- ein Mendix-11.12.1-MPR aus der Ruby-DSL erzeugen und validieren;
- über die echte CLI mit `--mode ruby --flymetothemoon` exportieren;
- Sinatra, Puma, ActiveRecord und RSpec bereitstellen, ohne Java-, JAR- oder
  Bytecode-Dateien zu erzeugen;
- Erzeugung, Aggregation, Verzweigung, CRUD und Seitenmetadaten in der
  Ruby-Runtime mit SQLite ausführen;
- eine unveränderte Anwendung kompilieren und das MPR strukturell mit der
  Quelle vergleichen;
- ein Attribut hinzufügen und einen Microflow durch idiomatisches Ruby ersetzen;
- erneut exportieren und nachweisen, dass Ruby-Code und Mendix-Modell einen
  zweiten strukturell identischen Roundtrip überstehen.

Der isolierte Test wird so ausgeführt:

```bash
bundle exec rspec spec/flymetothemoon_roundtrip_spec.rb
```

Für generierte Oberflächen wird das deklarative Szenario
[`spec/fixtures/frontend_browser/sudoku_full_flow.json`](../../spec/fixtures/frontend_browser/sudoku_full_flow.json)
mit `script/frontend_browser_acceptance` in einem echten Chromium ausgeführt.
Es deckt die Brettpositionen 73 und 74, Auswahl, Werteingabe sowie den Wechsel
zwischen Easy, Medium und Hard ab. Jeder kritische Klick wartet auf Microflow-POST
und Assoziations-GET und muss innerhalb von 250 ms enden. Galerieabfragen werden
in SQLite nach Kontext gefiltert; über eine inverse Assoziation geladene Objekte
behalten ihre Verknüpfung, wenn nur Attribute gespeichert werden.
