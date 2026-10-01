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
Member-Rechte und der sichere XPath-Teil werden für jede Anfrage geprüft.
Zugangsdaten stammen aus `MXRB_USERS_JSON` und `MXRB_AUTH_TOKENS` und gehören in
ignorierte lokale Dateien oder den Secret Manager des Deployments.

Scheduled Events laufen im stdlib-basierten MXRB-Scheduler mit Minuten-,
Stunden- und Tagesintervallen, Overlap-Schutz und kontrolliertem Shutdown.
IANA-Zeitzonen wie `Europe/Berlin` verwenden `tzinfo` und berücksichtigen
Sommerzeitwechsel. Unbekannte Zonen führen zu einem Fehler statt unbemerkt auf
UTC zurückzufallen; `UTC`, `local` und numerische Offsets werden ebenfalls
unterstützt.

Sitzungen und Scheduler-Koordination verwenden standardmäßig die native
SQLite-Datei `.mxrb/runtime/<Umgebung>-shared.sqlite3`, ohne externen Dienst.
Mehrere Instanzen müssen mit `MXRB_SHARED_STORE_PATH` dieselbe Datei verwenden.
Idempotente Claims pro Ereignis/Zeitfenster und per Heartbeat erneuerte
Overlap-Leases sind atomar; ein unvollständiger Claim kann nach Lease-Ablauf
übernommen werden. Der Standard-Lease beträgt 300 Sekunden und lässt sich über
`MXRB_SCHEDULER_LEASE_TTL` ändern. `:memory:`, `memory` oder `local` aktivieren
explizit den prozesslokalen Modus.

Java Custom Actions starten niemals eine JVM. Jede erlaubte Action benötigt
einen expliziten Ruby-Adapter, der in `config/adapters.rb` unter dem
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
ihrem Namen und einem Registrierungshinweis geschlossen fehl; es gibt weder
Klassenerkennung noch JAR-Ausführung oder JVM-Fallback. REST, App Services, SOAP,
Mappings und Dokumenterzeugung verwenden weiterhin typbezogene Ruby-Adapter.
Im Browser bleibt JavaScript/React; Backend und APIs laufen ohne Java Runtime.

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
