# Runtime ohne Java

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
