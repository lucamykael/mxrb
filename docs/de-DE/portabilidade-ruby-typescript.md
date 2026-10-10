# Echte Portabilität zwischen Ruby, TypeScript und Mendix

## OQL-Prädikate: `LIKE`, `IN`, `DISTINCT` und `HAVING`

Views und tabellarische Abfragen akzeptieren `LIKE`/`NOT LIKE` mit `%` und `_`
sowie `IN`/`NOT IN` mit Literal-Listen. Wie in Mendix 11.12.1 vergleichen `=`,
`!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `GROUP BY`, `DISTINCT`, `MIN`, `MAX` und
`ORDER BY` Zeichenfolgen ohne Beachtung der Groß-/Kleinschreibung. `NOT IN` mit
`NULL` in der Liste liefert keine Zeilen; `LIKE NULL` wirkt wie `LIKE ''`; die
leere Zeichenfolge und `NULL` bleiben verschiedene Werte und Gruppen.
`SELECT DISTINCT` und `HAVING` mit Aggregaten, gruppierten Spalten, `AND`, `OR`,
`NOT` und `IS NULL` funktionieren; `HAVING` verlangt `GROUP BY`. Die erste
gespeicherte Zeile vertritt eine Gruppe oder einen DISTINCT-Wert, der sich nur in
der Schreibweise unterscheidet.

Mendix lehnt `ESCAPE`, `BETWEEN`, `<>`, `HAVING` ohne `GROUP BY` und Spalten in
`IN` ab; MXRB ebenfalls. Funktionen, `CAST`, `CASE` und Arithmetik beschreibt der
Abschnitt OQL-Ausdrücke. Die Schreibweise wird mit Rubys `downcase` angeglichen;
Kollationen außerhalb von ASCII sind nicht zertifiziert.

Alle 37 Abfragen liefen mit dem offiziellen MxBuild und Runtime von Mendix
11.12.1 unter Linux über `script/oql_native_oracle`, ohne Windows-VM. Zwei native
Läufe stimmten überein und entsprachen Ruby bei Views, interpretierten Microflows
und der exportierten Anwendung ohne MPR-Zugriff.
[Nachweis](../evidence/oql-predicates-2026-10-09.json).

## Datenaktionen in Nanoflows

Nach TypeScript exportierte Nanoflows führen Datenbank-`Retrieve` (XPath, Sortierung,
erstes Objekt, `limit`/`offset`) und Assoziations-Retrieves, `Commit`, `Delete`,
`Rollback`, Listenoperationen (`Head`, `Tail`, `Union`, `Intersect`, `Subtract`,
`Contains`, `Sort`, `Find`/`Filter` nach Attribut oder Ausdruck), `Aggregate` und
Schleifen (`for each`, `while`, `break`, `continue`) aus. Datenbank-Retrieves laufen auf
dem Ruby-Server, der XPath, Reihenfolge und Zugriffsregeln anwendet; XPath-Variablen
(`$minimum`, `$objekt`) werden als `xpath_variables` mit lesbar autorisierten Objekten
übertragen. Wie im Client von Mendix 11.12.1 setzt das Listen-`Sort` leere Werte in
beiden Richtungen ans Ende, der Durchschnitt einer leeren Liste ist leer und ihre Summe
0. Log-Meldungen ersetzen jetzt `{1}`. Zuvor nutzten 49 der 183 Nanoflows aus Korpus
und SPC eine dieser Aktionen und schlugen fehl.

`script/client_native_oracle` führt dasselbe Fixture im offiziellen Client (MxBuild und
Runtime unter Linux, Chromium headless) und in der exportierten Ruby-App aus: alle 15
Fälle stimmen überein. [Nachweis](../evidence/nanoflow-data-actions-2026-10-09.json).

## Ausdrücke in Nanoflows

Der Mendix-Client wertet Nanoflow-Ausdrücke in JavaScript statt Java aus, und der
exportierte TypeScript-Auswerter folgt dieser im Client 11.12.1 gemessenen Semantik:
`trim` entfernt alle Unicode-Leerzeichen (auch NBSP), `toLowerCase('İ')` ergibt `i̇`,
`substring(Text, Start, Länge)` schlägt außerhalb des Bereichs nie fehl,
`find`/`findLast` entsprechen `indexOf`/`lastIndexOf`, `replaceAll`/`replaceFirst`/
`isMatch` nutzen reguläre Ausdrücke von JavaScript (`(?i)` ist ungültig, `isMatch` muss
den ganzen Text treffen) mit wörtlicher Ersetzung (`$1` wird nicht ausgewertet),
`urlEncode` ist `encodeURIComponent` und `urlDecode` liest `+` als Leerzeichen. Leere
Argumente gelten als `''`, `'a' + empty` ist `'a'` und verkettete Zahlen werden zu Text.
Ausgewertet werden außerdem `getCaption`/`getKey` (übersetzt nach der Seitensprache),
das Token `[%CurrentDateTime%]` und die Tokens `[%BeginOf…%]`/`[%EndOf…%]` für Minute,
Stunde, Tag, Monat und Jahr (das Ende ist der Beginn des nächsten Zeitraums minus 1 ms,
in der Zeitzone der Sitzung oder UTC), Pfade `$obj/Modul.Assoz/Modul.Entität/Attribut`
über die vom Server mitgesendeten zugeordneten Objekte sowie Objektgleichheit nach
Identität. In den 1.146 Ausdrücken der Nanoflows aus Korpus und SPC bleibt keine
Funktion und keine Syntax ohne Unterstützung. Die 27 Fälle von
`spec/fixtures/native_nanoflow_expressions` stimmen zwischen offiziellem Client und
Ruby-App überein. [Nachweis](../evidence/nanoflow-expressions-2026-10-09.json).

## Datums- und Zahlenfunktionen in Nanoflows

Der Mendix-Client formatiert und liest Nanoflow-Datumswerte mit der Bibliothek date-fns;
das exportierte Frontend nutzt dieselbe Bibliothek mit der Musterumwandlung des
11.12.1-Clients: Java-Buchstaben ohne Entsprechung (`W`, `F`, `z`, `Z`, `X`) werden zu
Literaltext, `E`/`EE` und `S`/`SS` werden zu `EEE` und `SSS` erweitert, `u` ist der
ISO-Wochentag und jeder andere unbekannte lateinische Buchstabe ist ein Fehler.
`formatDateTime[UTC]` ohne Muster, `formatDate[UTC]` und `formatTime[UTC]` nutzen den
Kurzstil der Sitzungssprache (auf Englisch `3/5/24, 2:07 PM`, mit schmalem Leerzeichen
vor AM/PM), `toString` eines Datums denselben Stil mit vierstelligem Jahr.
`parseDateTime[UTC]` ist strikt (lehnt den 30. Februar, Suffixe und ungültige Stunden ab),
versucht zuerst das zweistellige Jahr und begrenzt das Jahr nicht auf 1800–9999. Monats-
und Tagesnamen, AM/PM, Ären und Wochenregeln stammen aus der Sitzungssprache.

`parseInteger`, `min`/`max` (Zahlen oder Datumswerte), `pow`, `sqrt`, `random`,
`millisecondsBetween` … `weeksBetween` (Betrag, dezimal), `calendarMonthsBetween`,
`calendarYearsBetween` und die Tokens `[%BeginOf/EndOfCurrentWeek%]`,
`[%BeginOf/EndOfYesterday%]` und `[%BeginOf/EndOfTomorrow%]` (mit UTC-Varianten, deren Woche
immer am Sonntag beginnt) folgen dem big.js des Clients: Quotienten, Wurzeln und Abstände
haben 20 Nachkommastellen mit der Rundung des Projekts, Zahlen ab 1e21 oder unter 1e-6
erscheinen in Exponentialschreibweise. `formatDecimal` und `trimToWeeks` gibt es in
Nanoflows nicht. Die 42 Fälle von `spec/fixtures/native_nanoflow_functions` (9 erwartete
Fehler), gemessen mit dem Browser in America/New_York, stimmen zwischen offiziellem Client
und Ruby-App überein. Andere Sprachen nutzen die Namen des Browsers und wurden im
offiziellen Client nicht zertifiziert.
[Nachweis](../evidence/nanoflow-functions-2026-10-10.json).

## Ausdrucksfunktionen in Microflows

Anders als in XPath und OQL beachten Textvergleiche in Ausdrücken (`=`, `<`) sowie
`contains`, `startsWith` und `endsWith` die Groß-/Kleinschreibung, wie Mendix 11.12.1.
`replaceAll`, `replaceFirst` und `isMatch` nutzen reguläre Ausdrücke von Java; `isMatch`
verlangt den ganzen Text und der Ersatztext ist wörtlich (`$1` ist keine Gruppe).
`pow` rechnet mit Doubles, `sqrt` mit 38 signifikanten Stellen, `max`/`min` behalten den
Typ, `parseInteger` lehnt Leerzeichen und Brüche ab, und `formatDecimal` folgt Javas
`DecimalFormat` und rundet die Hälfte auf (`'#,##0.00'`, `%`, `E0`, Präfixe). Text plus
Zahl nutzt die Form von `toString` (`'x' + 1.0` ist `x1`); Text mit Boolean oder
`empty` wird abgelehnt. Parameter von Meldungen und Logs bewahren `\` und `$`.

Alle 95 Fälle liefen mit `script/oql_native_oracle` auf dem offiziellen Runtime und
stimmen mit dem Ruby-Interpreter überein.
[Nachweis](../evidence/expression-functions-2026-10-09.json).

## Datumsformatierung in Microflows

`formatDateTime`, `formatDateTimeUTC`, `formatDate`, `formatTime` und `toString` für
Datumswerte folgen Javas `SimpleDateFormat` für `en_US`, wie Mendix 11.12.1: die
Buchstaben `G y Y M L d D E u a h H k K m s S z Z X w W F`, Text in Anführungszeichen
und `''`. `S` zählt Millisekunden (`S` → `45`), `Y` und `w` nutzen am Sonntag
beginnende Wochen, `MMMM`/`EEEE` volle Namen. Formen ohne Muster nutzen die kurzen
Formate von JDK 21 (`3/10/24, 7:05 AM`) mit schmalem geschütztem Leerzeichen vor
AM/PM. Lokale Formen nutzen die Zeitzone der Sitzung, im Systemkontext UTC.
Zeitzonennamen (`z`) sind nur für UTC erlaubt; unbekannte Buchstaben werden
abgelehnt. Zuvor übersetzte der Ruby-Runtime wenige Muster in `strftime` und
ignorierte `SSS`, `h`, `a` und Anführungszeichen.

Alle 55 Fälle liefen mit `script/oql_native_oracle` auf dem offiziellen Runtime und
stimmen mit dem Ruby-Interpreter überein. TypeScript-Nanoflows, die im Client formatieren, bleiben ein eigener
Arbeitsbereich.
[Nachweis](../evidence/date-formatting-2026-10-09.json).

## Einlesen von Datumswerten in Microflows

`parseDateTimeUTC` und `parseDateTime` folgen in Microflows dem strikten
`SimpleDateFormat` für `en_US`: Monats- und Tagesnamen in beliebiger Schreibweise
(`MMM` akzeptiert auch den vollen Namen), zweistelliges `yy` im Fenster von 80 Jahren
vor bis 20 Jahren nach heute, `h`/`K`/`k` mit `a`, `D` (Tag im Jahr), `w` (US-Woche),
`G` sowie die Zeitzonen `Z`, `X` und `z` (`UTC`, `GMT`, `EST` und der lange Name von
UTC). Fehlende Felder ergeben 1970-01-01; ein gültiges Präfix wird akzeptiert;
widersprüchliche Wochentage, Stunden außerhalb des Bereichs, unbekannte Namen, das
Jahr 0 und zusätzliche Leerzeichen vor Namen lehnen den Text ab. `parseDateTime`
liest die Uhrzeit in der Zeitzone der Sitzung (im Systemkontext UTC).

Mendix nutzt vor dem 15.10.1582 den julianischen Kalender; MXRB lehnt diese Daten
ausdrücklich ab, statt sie zu verschieben. Die übrigen 80 Fälle liefen mit
`script/oql_native_oracle` auf dem offiziellen Runtime und stimmen mit Ruby überein.
TypeScript-Nanoflows behalten die numerische Teilmenge unten.
[Nachweis](../evidence/date-parsing-2026-10-09.json).

## OQL-Ausdrücke

Projektionen, `WHERE`, `HAVING` und `ORDER BY` von Datasets akzeptieren Arithmetik
(`+`, `-`, `*`, Division `:` und `%`), Verkettung mit `+`, einfache und bedingte
`CASE`, `CAST` nach `STRING`, `INTEGER`, `LONG`, `DECIMAL`, `BOOLEAN` und `DATETIME`
sowie `LOWER`, `UPPER`, `LENGTH`, `REPLACE`, `COALESCE`, `ROUND`, `DATEPART` und
`DATEDIFF`. Die Semantik wurde an der HSQLDB von Mendix 11.12.1 gemessen: `/` trennt
Pfade und dividiert nicht; Ganzzahldivision schneidet ab; Dezimaldivision schneidet
bei der größeren Operandenskala ab (`3 : 4.0 = 0.7`); `%` schneidet die Operanden ab;
`ROUND` rundet die Hälfte von null weg; Verkettung behandelt `NULL` als `''`, während
`UPPER`, `LENGTH` und Arithmetik `NULL` weitergeben; `REPLACE` beachtet die
Schreibweise; ein Dezimalwert wird mit acht Nachkommastellen zu Text; Datumswerte
nutzen UTC, `WEEK` ist die ISO-Woche, `WEEKDAY` beginnt am Sonntag und `DATEDIFF`
zählt überschrittene Grenzen.

Wie in Mendix schlagen fehl: ein untypisiertes `NULL`-Literal in Arithmetik,
`REPLACE` mit `NULL`, `CAST` nach `INTEGER` außerhalb von 32 Bit, Division durch null,
nicht konvertierbarer Text und ungeprüfte Datumsteile. Alle 78 Abfragen liefen mit
`script/oql_native_oracle` auf dem offiziellen MxBuild und Runtime und stimmen mit
Ruby überein. [Nachweis](../evidence/oql-expressions-2026-10-09.json).

## Retrieves mit XPath

Wie in Mendix 11.12.1 beachten XPath-Zeichenfolgenvergleiche (`=`, `!=`, `<`, `>=`)
sowie `contains`, `starts-with` und `ends-with` die Groß-/Kleinschreibung nicht.
Zuvor unterschied der Ruby-Runtime sie, sodass `[Name = 'NORTH']` `North` nicht
fand. Die 44 Fixture-Fälle mit `empty`, `not()`, Booleans, Dezimalwerten, Vorrang von
`and`/`or`, verketteten Prädikaten, `string-length` und Datumsfunktionen liefen mit
`script/oql_native_oracle` auf dem offiziellen Runtime und stimmen mit Ruby überein.
[Nachweis](../evidence/xpath-retrieve-2026-10-09.json).

## Sortierung von Retrieves und Grids

Sortierte Datenbank-Retrieves, serverseitig sortierte DataGrids und
Seitendatenquellen folgen der Datenbankreihenfolge von Mendix 11.12.1: `NULL`
steht bei `ASC` und `DESC` zuerst; die leere Zeichenfolge ist eine gewöhnliche,
kleinste Zeichenfolge; Zeichenfolgen werden ohne Groß-/Kleinschreibung und ohne
numerische Kollation verglichen (`a10` vor `A9`); `false` steht vor `true`.
Gleichstände gehen an den nächsten Schlüssel und behalten zuletzt die
gespeicherte Reihenfolge. Zuvor sortierte Ruby `NULL` bei `ASC` ans Ende, beachtete
die Schreibweise und konnte Booleans nicht sortieren; TypeScript nutzte die
numerische Kollation des Browsers.

Alle acht Fixture-Reihenfolgen liefen mit `script/oql_native_oracle` auf dem
offiziellen Runtime und stimmen mit dem Ruby-Interpreter, dem serverseitigen Grid
und `sortRecords` im Frontend überein.
[Nachweis](../evidence/retrieve-sort-2026-10-09.json).

Die Listenoperation `Sort` sortiert im Speicher nach einer anderen, ebenfalls am
Runtime gemessenen Regel: `NULL` steht in beiden Richtungen am Ende, und bei
Zeichenfolgen, die sich nur in der Schreibweise unterscheiden, kommt die
Kleinschreibung zuerst, wie bei einem Java-Collator. Zuvor ignorierte der
Ruby-Runtime die Schlüssel, und der Export verlor sie; jetzt bewahrt
`list_operation :sort, :liste, sort: [[attribut, :ascending]], as: :sortiert`
sie über zwei Zyklen Ruby → MPR. Satzzeichen und Akzente sind nicht zertifiziert.
[Nachweis](../evidence/list-sort-2026-10-09.json).

## OQL-Datasets und tabellarische Abfragen

Vorhandene OQL-Datasets werden nach `app/datasets` exportiert. Der Abfragetext
kann in Ruby bearbeitet werden und bleibt im Weg Ruby → MPR → Ruby erhalten.
Geprüfte Adapter für `Hr.RetrieveDatasetOql` und `Hr.RetrieveAdvancedOql` führen
benannte Datasets oder Abfragetext auf dem Ruby-Datenbestand aus. Die Registrierung
verlangt einen bekannten Java-Quellhash; geänderte Implementierungen benötigen
einen expliziten Adapter.

Die Teilmenge umfasst relationale Joins und Aggregate, `ORDER BY` für projizierte
Spalten oder Aliase, `LIMIT`, `OFFSET` und eine abgeleitete Quelle in `FROM` mit
bis zu 16 Ebenen. Sortierte Unterabfragen erfordern `LIMIT` oder `OFFSET`.
`LIMIT 0` begrenzt das Ergebnis nicht. Zertifiziert ist die Nullsortierung am
Anfang für `ASC` und `DESC`, entsprechend Mendix 11.12.1 mit HSQLDB. Andere
Datenbanken und Kollationen sind nicht zertifiziert. Gleiche Sortierschlüssel
haben keine garantierte relative Reihenfolge.

Die Aktionen erzeugen unterschiedliche Objekte ohne Commit, kopieren kompatible
Attribute und ignorieren unbekannte Spalten wie die geprüften Java-Implementierungen.
Abfragen lesen gespeicherte Werte und prüfen Namen, Typen und Syntax vor dem Lesen.
Die DSL lehnt das Anlegen, Entfernen, Umbenennen und Ändern von Dataset-Metadaten
ab. Für diese beiden Aktionen bleiben Quellen ohne OQL, `SELECT *` und Joins mit
abgeleiteten Quellen außerhalb dieser Teilmenge; Parameter gehören zum OQL-Modul (unten); Unterabfragen sind weiter unten beschrieben. Jede Projektion benötigt einen expliziten Alias.

Die Matrix enthält 18 Abfragen über beide Aktionen, darunter zwei echte Abfragen
aus `QueryApiBlogPost`. Im Ruby-Browser ist der MPR-Zugriff gesperrt.
[Nachweis](../evidence/oql-datasets-2026-10-08.json).

## Relationale OQL-Views

Der Ruby-Runtime unterstützt `INNER`, `LEFT`, `RIGHT` und `FULL` Joins zwischen
persistenten Entitäten, mit `ON` oder einem Assoziationspfad (auch mehrstufig, bei `INNER` und `LEFT`).
`GROUP BY`, `COUNT(*)`, `COUNT(Spalte)`, `SUM`, `AVG`, `MIN` und `MAX` erhalten
Duplikate, NULL-Gruppen, exakte Dezimalwerte und Datumswerte. IDs verknüpfter
Entitäten können kompatible Referenzassoziationen projizieren. Abfragen lesen
gespeicherte Werte; Gruppen-IDs bleiben nach Commits stabil. Namen, Klauseln und
Typen werden auch bei leeren Quellen vorab geprüft. OQL wird nie als SQL ausgeführt.

Die relationale Grammatik beginnt mit `SELECT` und verlangt Projektionsaliase.
Parameter bleiben offen; Unterabfragen, `UNION` und Views über Views stehen im
nächsten Abschnitt;
`LIKE`, `IN`, `DISTINCT` und `HAVING` sind oben beschrieben. Native Views
[erlauben kein `ORDER BY`](https://docs.mendix.com/refguide/use-view-entities/);
die Sortierung erfolgt beim Verbraucher. Das geprüfte explizite Datumsmuster von
`formatDateTimeUTC` funktioniert auch für Aggregatergebnisse; siehe
Datumsformatierung in Microflows.

Alle 22 Ergebnismengen stimmen zwischen originalem Mendix, dem Ruby-Roundtrip
in Mendix und dem Ruby-Browser ohne MPR-Zugriff überein. Zwei native Builds und
Runtimes sowie 197 Browserschritte bestanden mit unveränderten Eingabe-Hashes.
[Nachweis](../evidence/oql-relational-views-2026-10-08.json).

## OQL-Unterabfragen, `UNION` und Views über Views

Views und tabellarische Abfragen akzeptieren `IN (SELECT …)`, `NOT IN (SELECT …)`,
`EXISTS (SELECT …)`, `NOT EXISTS` und Wert-Unterabfragen in `WHERE`, `HAVING` und
Projektionen, auch mit der äußeren Abfrage korreliert und verschachtelt. Wie in
Mendix 11.12.1 braucht eine Wert-Unterabfrage eine Aggregatfunktion als Spalte oder
`LIMIT 1`; mit `GROUP BY` schlägt sie fehl, wenn sie mehrere Zeilen liefert. Eine
Unterabfrage wählt genau eine Spalte und darf mit `LIMIT` nach Quellspalten sortieren.
`NOT IN` mit einem `NULL`-Kandidaten wählt nichts aus; Textvergleiche ignorieren die
Groß-/Kleinschreibung.

`UNION` entfernt Duplikate ohne Rücksicht auf Groß-/Kleinschreibung, `UNION ALL`
behält sie; die Spalten tragen die Namen des ersten Teils. Eine View kann eine andere
View in `FROM` oder in Joins lesen, auch verkettet; eine View, die sich selbst liest,
wird abgelehnt. Mendix lehnt `ANY`, `ALL`, `BETWEEN` und `SELECT *` ab, `Count` ist
ein reserviertes Wort.

Die 30 Fälle von `spec/fixtures/native_oql_subqueries` stimmen zwischen offiziellem
Runtime (`script/oql_native_oracle`), Ruby-Interpreter und exportierter Ruby-App mit
gesperrtem MPR-Zugriff überein.
[Nachweis](../evidence/oql-subqueries-2026-10-10.json).

## OQL-Parameter und das OQL-Modul aus dem Marketplace

`OQL.ExecuteOQLStatement`, `OQL.CountRowsOQLStatement` und die Aktionen
`OQL.Add…Parameter` des OQL-Moduls haben Adapter, die über den SHA-256 der Quelle jeder
Aktion und von `oql/implementation/OQL.java` ausgewählt werden; MXRB verteilt diesen
Code nicht. Wie im Modul gelten Parameter je Thread bis zur Ausführung, die sie
verwirft, außer mit `preserveParameters`. Die Anweisung ist ein Dataset-Name oder OQL
mit `$Name`-Parametern für Text, Ganzzahl, Dezimal, Boolean, Datum oder Objekt (über
die ID verglichen); `amount` und `offset` blättern nach `ORDER BY`. Jede Spalte füllt
das gleichnamige Attribut oder, bei IDs, die eigene Assoziation `Modul.Spalte`; Spalten
ohne Ziel sind Fehler. Ein leerer Parameter in `=` wirkt wie `IS NULL`, wie das
Literal `NULL`; ein nicht gesetzter Parameter ist ein Fehler. Enum-Attribute werden
über ihren Schlüssel gelesen, auch in Filtern.

Joins akzeptieren mehrstufige Assoziationspfade (`p/M.A_B/M.B/M.B_C/M.C AS c`) bei
`INNER` und `LEFT`; Ordnungsvergleiche akzeptieren Datumswerte. Die neun SPC-Datasets,
vier davon mit Parametern, werden in Ruby kompiliert und ausgeführt. Die 15 Fälle von
`spec/fixtures/native_oql_parameters` (Modulquellen aus `MXRB_OQL_MODULE_SOURCE`)
stimmen zwischen offiziellem Runtime und exportierter Ruby-App mit gesperrtem
MPR-Zugriff überein. [Nachweis](../evidence/oql-parameters-2026-10-10.json).

## Aufnahme und Annotation mit Web Feedback

Für `JS_ToggleFeedbackScreenshotWidget` und `JS_ToggleFeedbackAnnotateWidget`
werden Adapter anhand des ursprünglichen Quellcode-Hashes ausgewählt. Der Export
kopiert das geprüfte ESM-Bundle aus der projekteigenen Datei
`SprintrFeedbackWidget.mpk` zusammen mit seiner Lizenz; MXRB verteilt diesen Code
nicht. Die drei erkannten Bundles behalten Schaltfläche, Beschriftungen, ältere
Aktion, Zielcontainer und Aufnahmeoptionen. Das passende Theme muss ebenfalls
vom Projekt bereitgestellt werden.

Der Ablauf unterstützt Zeichnen, Löschen, Speichern als PNG und Abbrechen.
Beim Abbruch einer Aufnahme wird `uploadCancelled` zurückgegeben; Annotationen
behalten den leeren Rückgabewert der Originalaktion. Gleichzeitige Vorgänge
werden abgewiesen. Das Entfernen des letzten Widgets beendet wartende Vorgänge.
Die Prüfung verwendet echte DOM-Aufnahmen und vergleicht die Pixel des annotierten
PNG, während der Ruby-Server nicht auf MPR zugreifen darf. Die Bildschirmauswahl
des Betriebssystems, Aufnahmeberechtigungen und Mobile/Offline sind nicht geprüft.

Das eingebettete html2canvas lehnt bestimmte moderne CSS-Farben
(`color()`/`color-mix()`) ab. Aufnahmetests verwenden das kompatible Theme der SLA
Task App; sie zertifizieren nicht alle Themes. Unbekannte oder veränderte Bundles
werden nicht automatisch registriert. Siehe
[Aufnahmenachweis](../evidence/feedback-capture-2026-10-08.json).

## Filter für OQL-Views

Projektionen einer persistenten Entität unterstützen `WHERE` mit `=`, `!=`, `<`,
`<=`, `>`, `>=`, `AND`, `OR`, `NOT`, Klammern und `IS [NOT] NULL`. Numerische
Literale behalten ihre Dezimalpräzision; Zeichenfolgen unterstützen doppelte
Anführungszeichen als Escape. Beide Formen `FROM ... WHERE ... SELECT` und
`SELECT ... FROM ... WHERE` funktionieren. Schlüsselwörter innerhalb einer
Zeichenfolge werden nicht als Klauseln interpretiert.

Vergleiche mit Mendix 11.12.1 bestätigen die NULL-Regeln: Gleichheit mit dem Literal
`NULL` wirkt wie `IS NULL`; Ungleichheit mit einem nichtleeren Literal schließt
NULL-Datensätze ein. Vergleiche zwischen Spalten erhalten den unbekannten Wert.
Filter lesen gespeicherte Werte, berücksichtigen Commits und Löschungen und prüfen
Attribute sowie Typen auch bei leeren Quellen. OQL wird niemals als SQL ausgeführt.
Ordnungsvergleiche verlangen Zahlen, Zeichenfolgen oder Datumswerte; Parameter beschreibt der Abschnitt zum OQL-Modul. Joins und Aggregate verwenden die oben beschriebene relationale Grammatik.

Die Matrix umfasst 30 Filter und 125 Browserschritte ohne MPR-Zugriff.
[Nachweis](../evidence/oql-view-filters-2026-10-07.json).

## Benutzer des System-Moduls

Der Ruby-Runtime speichert `System.User`, `System.UserRole`, `System.Language` und
`System.TimeZone` mit `System.UserRoles`, `System.User_Language`,
`System.User_TimeZone` und `System.grantableRoles` wie im System-Modell von Mendix
11.12.1. Entitäten wie `Administration.Account` erben die Attribute von `System.User`;
Abfragen von `System.User` schließen Spezialisierungen ein. Beim Start erhält jede
Benutzerrolle des Projekts ihre `System.UserRole` (`ModelGUID` = GUID der Rolle, Name
und Beschreibung). Wie im portablen Runtime wird der Administrator beim Start nicht
angelegt. `HashedString`-Attribute wie `Password` werden mit BCrypt (dem
Standardalgorithmus von Mendix) gespeichert und nie an den Browser gesendet.

`System.VerifyPassword` ignoriert die Groß-/Kleinschreibung des Benutzernamens und
berücksichtigt `Active`, `Blocked` und `WebServiceUser` nicht; ein leeres oder falsches
Passwort oder ein unbekannter Benutzer ergibt `false`. In Microflows liefert `length`
einer Liste die Anzahl der Elemente. Die 13 Ergebnisse von
`spec/fixtures/native_system_users` stimmen zwischen offiziellem Runtime und
exportierter Ruby-App mit gesperrtem MPR-Zugriff überein. Die Anmeldeseite nutzt noch
`MXRB_USERS_JSON`; die Anmeldung gegen `System.User` und `NanoflowCommons.SignIn` folgen.
[Nachweis](../evidence/system-users-2026-10-10.json).

## Bildupload im Feedback

`JS_UploadAndConvertToFileBlobURL`, `JS_RevokeUploadedFileFromMemory` und
`JS_Recalculate_MendixModal_Error_PopUp_Zindex` des Feedback-Moduls haben
TypeScript-Adapter, die über den SHA-256 der Quelle ausgewählt werden. Der Upload öffnet
ein verborgenes Dateifeld und liefert die `blob:`-URL oder die Texte des Moduls
(`uploadCancelled`, `fileTypeNotAccepted`, `fileSizeNotAccepted`, `fileNotConverted`).
Wie im Original ist jeder akzeptierte Typ ein regulärer Ausdruck für den MIME-Typ, und
die Grenze in MB ist die erste signifikante Ziffer des Werts plus 0,1 (`25` erlaubt
2,1 MB). Das Widerrufen gibt die URL frei oder schlägt ohne URL fehl; die
`z-index`-Korrektur wirkt nach 500 ms, der Warnungsselektor des Moduls ohne Punkt bleibt
wirkungslos. Ein Differenztest führte Originalquelle (mit big.js) und Adapter in 294
Szenarien ohne Unterschied aus.
[Nachweis](../evidence/feedback-file-actions-2026-10-10.json).

## Feedback-Metadaten im Browser

Die verifizierten Versionen von `JS_PopulateFeedbackMetadata` und `JS_isStrictMode`
aus den fünf Korpusprojekten haben Webadapter. Die Metadaten enthalten die
aktuelle Seite, die erste Benutzerrolle, URL, Browser und Bildschirmabmessungen.
Verschachtelte Nanoflows behalten den Aufrufkontext; Popups übernehmen die Rollen
ihres Arbeitsbereichs. Änderungen an Objektparametern werden auch bei ignoriertem
Rückgabewert erfasst.

Die Strict-Mode-Prüfung erstellt und verwirft einen Entwurf. Diese Weblaufzeit
unterstützt die Erstellung und liefert wie die ursprüngliche Aktion `false`,
auch bei asynchronen Fehlern. In der Legacy-Variante reproduzieren Abmessungen von null den nativen Fehler
bei der Zuweisung einer leeren Zeichenfolge an eine Ganzzahl: Die bisherigen
Abmessungen bleiben erhalten und der Fehler wird protokolliert.

Der Originalquelltext-Hash wählt drei Varianten: Bildschirmabmessungen mit Fehler
bei null (Sudoku und RubyBridgeSandbox), Bildschirmabmessungen mit numerischer Null
(SLA Task App) und Fensterabmessungen mit Leerwert bei null (MyFirstModule und
LearnNow). Sechs native Builds und Runtimes, 203 Frontendtests und 18 Browserschritte
ohne MPR bestanden. Screenshot-/Anmerkungsfunktionen sowie native und
Strict-Mode-Clients sind nicht zertifiziert.
[Nachweis](../evidence/feedback-browser-metadata-2026-10-07.json).

## Feedback-Objekte lesen und wiederherstellen

Die verifizierten Getter `JS_GetFeedbackStorageObject` und `GetStorageItemObject`
verwenden verfügbare Objekte erneut und aktualisieren das gespeicherte JSON.
Fehlende Objekte werden mit Dezimalwerten, Datumswerten und booleschen Werten
wiederhergestellt; die neue GUID ersetzt die alte im Speicher. Entitätstypen
werden korrekt an TypeScript-Nanoflows übergeben.

Die Wiederherstellung speichert das Objekt noch nicht dauerhaft. Persistente
Objekte erhalten eine benutzergebundene Entwurfsberechtigung für Microflows und
explizites Speichern. Bereits gespeicherte Objekte werden erneut beim Server
abgefragt; aktuelle Kontextwerte haben Vorrang vor alten Snapshots. Zugriffsfehler,
ungültige Speicherwerte und unbekannte Mitglieder führen zu Fehlern.

Zwei native Builds und Runtimes, 21 Browserschritte ohne MPR und drei Fälle des
unveränderten Getter-Nanoflows aus SLA Task App bestanden. Wiederhergestellte
Ganzzahlen müssen im exakten Zahlenbereich des Frontends liegen. Synchronisierung
zwischen Browsern, AsyncStorage und Offlinebetrieb sind nicht zertifiziert.
[Nachweis](../evidence/feedback-object-restore-2026-10-07.json).

## Numerische UTC-Datumswerte parsen

`parseDateTimeUTC(text, muster[, ersatzwert])` läuft in Ruby-Microflows und
TypeScript-Nanoflows ohne MPR-Zugriff. Unterstützt werden numerische Felder für
Jahr, Monat, Tag, Stunde, Minute, Sekunde und Millisekunde sowie zitierte Literale
und benachbarte Felder. In Nanoflows folgt das Muster dem Abschnitt Datums- und Zahlenfunktionen in
Nanoflows; Microflows folgen Einlesen von Datumswerten in Microflows. Ungültige
Eingaben liefern den optionalen Datums-/Leerwert oder einen Fehler.

Zwanzig Fälle wurden in beiden Ausführungsarten von Mendix 11.12.1 mit dem
Originalprojekt und dem rekonstruierten Projekt geprüft. Beide lehnen ungültige
Kalender- und Zeitkomponenten ab. Microflows akzeptieren ein gültiges Präfix und
numerische Zeitzonenversätze; Nanoflows lehnen nachgestellten Text und die geprüften
Versatzmuster ab. Reine Uhrzeiten verwenden in Microflows den 01.01.1970 und in
Nanoflows das aktuelle UTC-Datum. Diese beobachteten Unterschiede bleiben erhalten.
Namen, zweistellige Jahre und das lokale `parseDateTime` gelten nur in Microflows.

Die Ruby-Suite bestand 2.345 Beispiele mit 100 % Zeilen- und Zweigabdeckung.
Das Frontend bestand 190 Tests und 81 Browserschritte ohne MPR-Zugriff.
[Nachweis](../evidence/parse-datetime-utc-2026-10-07.json).

## Feedback-Objekte im Browser speichern

`JS_SetFeedbackStorageObject` und `SetStorageItemObject` verwenden anhand des
Quelltext-Hashs ausgewählte Web-Adapter. Die Modellparameter bleiben erhalten:
`key`/`value` für die erste Aktion und `Key`/`Value` für die zweite.

Das JSON enthält `guid`, Zahlen als Text, Datumswerte in Millisekunden und durch
das Modul qualifizierte Referenzen. False, null und leere Zeichenfolgen bleiben
erhalten; verwandte Objekte werden durch Kennungen dargestellt. Die Aktion nutzt
das aktuelle Ruby-Schema und verändert das Eingabeobjekt nicht. Unvollständige
Objekte, unbekannte Mitglieder und im Frontend nicht mehr exakt darstellbare
Ganzzahlen führen zu einem ausdrücklichen Fehler.

Beide Schreibaktionen stimmen in zwei Builds und zwei Laufzeiten mit Mendix
überein. Zwölf Vergleiche mit dem ursprünglichen JavaScript, zwei unveränderte
reale Nanoflows und 25 Browser-Schritte ohne MPR-Zugriff bestanden ebenfalls.
Das Lesen und Wiederherstellen von Objekten ist im obigen Abschnitt abgedeckt;
AsyncStorage und Offline-Synchronisierung sind noch nicht unterstützt.
[Nachweis](../evidence/feedback-object-storage-2026-10-07.json).

## Aktualisierung von Seitenparametern

Wenn sich das Kontextobjekt ändert, erhalten benannte Seitenparameter, die auf
dasselbe Objekt verweisen, dessen aktuellen Zustand. Data Views, bedingte Klassen
und Aktionsargumente bleiben dadurch nach Nanoflows und Microflows synchron.
Andere Objekte, primitive Werte und leere Argumente bleiben erhalten.

Die Regression reproduzierte den Notizmodus von Sudoku: Der Wert änderte sich,
doch die Seite zeigte weiterhin den ursprünglichen Zustand. Die reale Anwendung
bestand 32 Schritte ohne MPR-Zugriff; ein isolierter Test prüft wiederholtes
Umschalten und eine Microflow-Aktualisierung in 19 Schritten.
[Nachweis](../evidence/live-page-parameters-2026-10-07.json).

## Älteres Feedback und Frontend-Konstanten

`JS_GetSingleLocalStorageObjectItem`, verwendet von Sudoku und RubyBridgeSandbox,
erhält einen anhand des Quelltext-SHA-256 ausgewählten Adapter. Er verwendet die
Modellparameter `LocalStorageKey` und `ObjectItemKey` und liefert bei fehlenden
Einträgen `""`; der neuere Getter liefert dagegen `null`.

Frontend-Ausdrücke lösen `@Module.Constant` über die aktuellen, für den Client
freigegebenen Ruby-Definitionen auf. Private und ausgeschlossene Konstanten fehlen
im Schema; Integer, Boolean und Decimal behalten ihre Typen. Beim Laden der
Anwendung werden frühere Registrierungen ersetzt. Nicht verfügbare Referenzen
erzeugen explizite Fehler.

Die unverändert exportierten Nanoflows beider realer Projekte bestanden mit
fehlendem, leerem und gefülltem Speicher. Der Fixture verwendet eine Konstante
als Speicherschlüssel und prüft dasselbe Verhalten in Ruby und Mendix.
[Nachweis](../evidence/legacy-feedback-2026-10-07.json).

## Abfragbare OQL-Views erzeugen

`oql_view` erhält das Persistenzflag der Entität. Neue Views verwenden den für
Mendix-Datenbankabfragen erforderlichen persistenten Standard; die OQL-Quelle
verhindert weiterhin eine physische SQLite-Tabelle. Zuvor erzwang die Erzeugung
`Persistable=false`, wodurch MxBuild Abrufaktivitäten ablehnte. Nach der Korrektur
bestanden zwei Builds und zwei Laufzeiten in der Windows-VM mit identischen
Ergebnissen des Originals und Wiederaufbaus sowie unveränderten Hashes.
[Nachweis](../evidence/oql-view-persistence-2026-10-07.json).

Die Ruby-Laufzeit unterstützt außerdem einfache Projektionen einer persistenten
Entität: Spalten mit optionalen Aliasnamen und `ID` als Referenzassoziation.
Views lesen gespeicherte Werte, berücksichtigen Commits und Löschungen und
weisen Schreibzugriffe zurück. OQL-Text wird validiert und nie direkt als SQL
ausgeführt. Der Filterumfang und die relationale Erweiterung oben werden unterstützt;
verkettete Views erzeugen weiterhin explizite Fehler. Acht Ergebnisse stimmten zwischen
Ruby und beiden Mendix-Laufzeiten überein; 41 Browserschritte bestanden ohne
MPR-Zugriff. Der Modellabruf in acht realen Projekten bestand für alle 98
Entitäten, einschließlich `MyFirstModule.LocationsView`.
[Ausführungsnachweis](../evidence/oql-view-execution-2026-10-07.json).

## Nanoflow-Commons-Speicher

`GetStorageItemString`, `SetStorageItemString`, `RemoveStorageItem`,
`StorageItemExists` und `ClearLocalStorage` erhalten Web-Adapter, ausgewählt
anhand des SHA-256 der Originalquelle. Die Modellparameter heißen `Key` und
`Value`. Pflichtfeldfehler, fehlende gegenüber leeren Werten, Entfernen und
Leeren bleiben erhalten. `ClearLocalStorage` leert wie das Original den gesamten
Speicher des aktuellen Ursprungs.

Validierung: 60 Vergleiche mit dem Original-JavaScript, 176 Frontend-Tests,
51 Chromium-Schritte ohne MPR-Zugriff sowie zwei Builds und zwei Laufzeiten
in der Windows-VM mit identischen Ruby-Ergebnissen und unveränderten Hashes.
Alle 2.326 Ruby-Beispiele bestanden bei 100% Zeilen- und Zweigabdeckung.
Audit und identischer Wiederaufbau des echten Sudoku-Projekts bestanden.
[Nachweis](../evidence/commons-storage-2026-10-07.json).
Der Umfang ist Web-`localStorage`; React Native `AsyncStorage` ist nicht implementiert.

## Nanoflow-Commons-Aktionen und Listen

Der Export registriert `Base64Encode`, `Base64Decode`, `GetGuid`, `GetPlatform`
und `FindObjectWithGUID` nur bei übereinstimmenden Hashes der geprüften Quellen.
Base64 verwendet `js-base64` 3.7.7 aus der nativen Referenz. Die Registrierung
erhält den Modellparameter `EntityObject` und gleichzeitig die Feedback-Adapter.
Exportierte Nanoflows erstellen außerdem Listen und fügen Objekte hinzu,
entfernen sie oder leeren die Liste, ohne bestehende Listenreferenzen zu ersetzen.

22 Vergleiche mit dem Original-JavaScript, 169 Frontend-Tests und 13 Chromium-
Schritte ohne MPR-Zugriff bestanden. Zwei Builds und Runtimes in der Windows-VM
bestätigten identische Original-/Roundtrip-Ergebnisse und unveränderte Quellen.
Das Szenario zertifiziert Web; Umgebungserkennung ist keine Zertifizierung
einer React-Native- oder Cordova-Anwendung.
[Nachweis](../evidence/nanoflow-commons-2026-10-07.json).

## CustomChart mit Plotly

`CustomChart` lädt Plotly 3.0.1 bei Bedarf und übernimmt JSON-Daten, Layout und
Konfiguration aus dem Modell. Statische und attributgebundene Datenreihen werden
aneinandergefügt; Kontextänderungen zeichnen das Diagramm neu. Abmessungen,
Höhenbegrenzungen, Legenden, Achsen und Werkzeugleiste bleiben erhalten. Ein Klick
schreibt die `bbox` des ersten Punktes ins Ereignisattribut, führt die konfigurierte
Aktion aus und leert das Attribut. Laufende Aktionen werden geschützt; beim
Entfernen der Komponente wird das Diagramm freigegeben.

Die Abnahme vergleicht Datenreihen, Titel, Skala, Größe und Klickverhalten vor und
nach einer Änderung. 160 Frontend-Tests und zehn Chromium-Schritte ohne MPR-Zugriff
bestanden. Die vollständige Engine lädt bei Bedarf etwa 1,33 MB gzip. Der interne
Playground/Editor, seine Initialisierungseffekte auf Beispieldaten und die
Zertifizierung sämtlicher Diagrammtypen sind nicht enthalten. Die übrigen
Diagramm-Widgets behalten ihren bisherigen Optionsumfang.

Die Windows-VM bestätigte beide Builds und Runtimes, Original und Roundtrip,
mit identischen Ruby-Ergebnissen und unveränderten Eingabe-Hashes.
[Nachweis](../evidence/custom-plotly-2026-10-07.json).


## Speicheraktionen im Browser

Drei Aktionen des Feedback Module erhalten TypeScript-Adapter, wenn der Hash
der Originalquelle übereinstimmt: Wert lesen, `ShowEmail` lesen und `ImageB64`
schreiben. Die Registrierung erhält Parameternamen und deren Groß-/Kleinschreibung.
Ungültiges JSON, fehlende Werte und Speicherfehler behalten das geprüfte Verhalten.

Alle 33 Vergleiche mit dem Original-JavaScript bestanden. Chromium führte zehn
Schritte ohne MPR-Zugriff aus, einschließlich Persistenz nach neuer Navigation.
Die Windows-VM bestätigte identische Ergebnisse im Original und im Roundtrip.
Geänderte Quellen, natives AsyncStorage und Offline-Synchronisation sind nicht
enthalten. Siehe den [Nachweis](../evidence/feedback-storage-2026-10-07.json).

## Java-Adapter anhand geprüfter Quellen

Der Export erkennt zwei Implementierungen des Feedback Module am SHA-256 der
Java-Quelle: `ValidateEmail` und `XSS_Sanitizer`. Nur geprüfte Versionen erzeugen
explizite Registrierungen in `config/adapters.rb`; fehlende oder geänderte
Quellen benötigen weiterhin einen projektspezifischen Adapter. Die Ausführung
verwendet Ruby ohne MPR oder JVM. Registrierungen bleiben editierbarer Ruby-Code.

Die Tests vergleichen 32 Eingaben mit dem Java-Original, einschließlich Unicode,
leerer Werte und null. Die ältere Aktion `XSS_Sanitizer` behält ihr Verhalten
mit regulären Ausdrücken; sie ersetzt weder HTML-Escaping noch eine
Sanitierungsrichtlinie der Anwendung. Weitere Java-/JavaScript-Aktionen und
externe Integrationen brauchen eigene Implementierung und Abnahme.

## Strukturierte Beschriftungen

Beschriftungen unterstützen Übersetzungen, Ersatztexte, Attribut- und
Ausdrucksparameter, Zahlen-/Datumsformate sowie Seiten-, Snippet- und
Widget-Objekte. Ruby-Deklarationen erhalten diese Metadaten beim Roundtrip.
Das Frontend verwendet die gewählte Sprache und bewahrt Decimal-Präzision
auch jenseits des exakten Number-Bereichs. Serien behalten ihren Kontext.

Das Szenario chart-captions vergleicht Namen und Werte vor und nach einer
Änderung in der nativen Runtime. Unbekannte Datumsmuster werden ausdrücklich
abgelehnt. Erweiterte Plotly-Optionen bleiben ein separater Arbeitsbereich.

## Decimal-Präzision

Ruby verwendet `BigDecimal`, das Frontend `decimal.js`. Decimal-Literale,
Arithmetik und Vergleiche vermeiden zwischenzeitliche `Float`-/`Number`-Konvertierungen.
Die Division nutzt 38 signifikante Stellen entsprechend der installierten Runtime
11.12.1. `round` berücksichtigt `HalfUp`/`HalfEven`; der Export übernimmt `DecimalScale`.
Auch `floor`, `ceil`, `abs` und `parseDecimal` ohne Format arbeiten mit exakten Werten.

Die interne API überträgt Decimal als `{"__mxrb_decimal":"9007199254740993.12345678"}`.
TypeScript-Erweiterungen verwenden die Hilfsfunktionen aus `bridge/decimal`.
Eingabefelder, Seitenparameter, Filter, Sortierung, Entwürfe und Nanoflows erhalten
die Genauigkeit. Diagrammkoordinaten werden erst zur Darstellung in Gleitkommazahlen umgewandelt.

SQLite speichert kanonischen Decimal-Text. Beim Commit gelten Skalierung,
Rundung und Wertebereich des Projekts. Vorhandene `REAL`-Spalten werden unter
Erhalt der Zeilen migriert; bereits verlorene Stellen lassen sich nicht rekonstruieren.
Externes SQL benötigt dezimale Vergleiche statt textueller SQLite-Sortierung.
API-Clients müssen das Decimal-Tag zusammen mit dem neu generierten Frontend übernehmen.
Lokalisierte Formatierung und Java-Formatmuster sind weiterhin nicht abgedeckt.

[Decimal-Nachweise](../evidence/decimal-runtime-2026-10-06.json).

## Kalenderausdrücke

Ruby und TypeScript unterstützen Datumserzeugung, Addition/Subtraktion von
Millisekunden bis Jahren, Periodenanfänge und Epoch-Konvertierung in Millisekunden.
Kalenderoperationen haben UTC-Varianten. Ruby verwendet die IANA-Zeitzone des
Sicherheitskontexts; das Frontend verwendet die Browser-Zeitzone oder eine explizite
`timeZone`. Folgeanfragen übernehmen keine Zeitzone vorheriger Benutzer.
Monats-/Jahresoperationen begrenzen den Tag auf das Monatsende; Stunden und kleinere
Einheiten sind Zeitdauern, Kalendertage behalten die lokale Uhrzeit bei DST-Wechseln.

Lokale Tests prüfen New York, Lord Howe und Apia. Die native Matrix ergänzt 16
UTC-Fälle für Original und Round-trip. Lokale Tests allein belegen keine native
Gleichwertigkeit. Die Formatierung beschreibt Datumsformatierung in Microflows; das
Einlesen lokalisierter Texte bleibt ein separater Vertrag.


[Calendar evidence](../evidence/calendar-expressions-2026-10-06.json).

## Gestapelte Diagramme und Punktaktionen — 6. Oktober 2026

Balken- und Säulendiagramme unterstützen `barmode: "stack"`. Die Basiswerte
werden je Kategorie in der Reihenfolge der Datenreihen addiert, einschließlich
negativer Werte und Null. Die Achsenskalierung berücksichtigt Basis und Summe.
`staticOnClickAction` und `dynamicOnClickAction` verwenden die Ereignislaufzeit
der Seite mit dem Datensatz des Punkts, Bestätigung und Ausführungssperre.
Klick, Enter, Leertaste und die zugängliche Datentabelle lösen die Aktion aus.

Bei Aggregation entspricht der Punktindex dem Index in der sortierten
Quelldatenliste, wie beim zertifizierten Mendix-Charts-Paket; dies ist nicht
zwingend der erste Datensatz der aggregierten Kategorie. Punktaktualisierungen
erhalten den Seitenkontext. `chart-interactions` prüft beide Ausrichtungen,
Aggregatklicks, negative Werte und eine neu erstellte Datenreihe.

Die Aggregation horizontaler Balken wird weiterhin nicht unterstützt: Das Charts-Paket gruppiert nach der numerischen Achse und kann Beschriftungen verketten. Die Ruby-Laufzeit meldet diese Einschränkung ausdrücklich. Die horizontale Zertifizierung verwendet nicht aggregierte Punkte, einschließlich wiederholter Kategorien.

## Dynamische Diagrammreihen — 6. Oktober 2026

Linien- und Säulendiagramme unterstützen dynamische Reihen, gruppiert nach dem
konfigurierten Attribut, mit Quellsortierung und eigener Aggregation pro Gruppe.
Datenänderungen aktualisieren Punkte und ergänzen Gruppen. Typisierte
Ruby-Eigenschaften akzeptieren
`caption("Region {1}", parameters: ["$currentObject/App.Point.Region"])`;
das Frontend wertet Parameter im Datensatz der Reihe aus. Zahlen und gleich
lautende Zeichenketten bleiben unterschiedliche Gruppen.

Geprüft sind einfache Ausdrucks- und Attributparameter. Übersetzungen,
benutzerdefinierte Formatierung und andere Seitenvariablen sind durch diese
Caption-Projektion nicht zertifiziert. Stapelung, Punktaktionen und erweiterte
Plotly-Optionen bleiben offen. Der Windows-Workflow führt `chart-series` sowohl
für das ursprüngliche als auch für das rekonstruierte Modell aus.

## Aktualisierung vom 5. Oktober 2026

Der Runtime-Katalog erkennt neue Modelle, DTOs, Seiten, Enumerationen und Dienste
aus geladenen Ruby-Dateien ohne manuelle Manifeständerungen. Anwendungen mit
`runtime_model: ruby` laufen ohne MPR-Zugriff; ältere Exporte müssen dafür erneut
exportiert werden. Löschen und Umbenennen alter Katalogeinträge erfordern noch
einen ausdrücklichen Abgleich.

UI-Regeln kombinieren Modulrollen und Sichtbarkeits-/Editierbarkeitsausdrücke mit
geerbten Data-View-Einschränkungen. Unbekannte Rollen gewähren keinen Zugriff;
Serverberechtigungen bleiben maßgeblich. XPath unterstützt zusätzliche String-
und Datumsfunktionen, Perioden und Sitzungszeitzonen, einschließlich kalender-
gerechter Monats-/Jahresgrenzen und DST-Tests. Das belegt keine universelle
Gleichheit aller Datenbanken und nativen Funktionen.

Persistente und transiente Callbacks erreichen Untertypen. Geerbte Validierungen
prüfen Pflichtwerte, Eindeutigkeit über Untertyptabellen, Gleichheit, inklusive
Intervalle und UTF-16-Länge beim Commit mit Events. Fehler rollen Transaktionen
zurück und liefern strukturiertes HTTP-422-Feedback. JVM-Regulärausdrücke brauchen
einen expliziten `regular_expression`-Adapter; unbekannte Regeln werden abgelehnt.
Eine Matrix aus 21 Fällen stimmt mit der nativen Runtime überein
([Evidenz](../evidence/validation-parity-2026-10-05.json)). Gleichheit verwendet
`Value` im nativen Speicher. Datumsgrenzen ohne Uhrzeit sind geprüft; eine von
MxBuild akzeptierte Grenze mit Uhrzeit wurde beim Runtime-Start abgelehnt.

Geänderte VetClinic-Ruby-Quellen bestanden Dienstausführung, neue Modellspalte,
Seitenprojektion, Persistenz nach Neustart, Rollback und Löschen bei verbotenem
MPR-Zugriff ([Evidenz](../evidence/vetclinic-ruby-2026-10-05.json)). Native
Lifecycle-Callbacks teilen jetzt die API-Transaktion.

Die [Windows-Zertifizierung](windows-studio-pro.md) bestand sechs lokale native
Builds und CRUD in der offiziellen Runtime. VetClinic bestand Darstellung mit
Theme und native Client-API-CRUD. Der [Bericht](../evidence/native-2026-10-05.json)
grenzt dies von vollständiger Formular-, Theme-, Fremdwidget-, Java/JS- und
Mobil-Layout-Parität ab. Der wöchentliche Workflow ergänzt native Builds und
Headless-Runtime-Prüfungen.

## Hauptrichtung: Mendix → Ruby + React/TypeScript

Ziel ist ein editierbares Ruby-Backend mit React/TypeScript-Frontend ohne Mendix-
Runtime. Die Rückübersetzung in ein MPR ist ein zusätzlicher Vertrag.
`runtime_only` bedeutet nicht uneditierbar. `portability --require-native` prüft
Ruby → Mendix, nicht die Vollständigkeit der Konvertierung nach Ruby.

Alte Exporte können weiterhin eine interne MPR-Kopie lesen. Neue Exporte mit
`runtime_model: ruby` erzeugen das Laufzeitmodell aus Ruby-Definitionen.
Nicht übersetzte Varianten, Custom Actions ohne Adapter und nicht unterstützte
Widgets bleiben offene Konvertierungslücken.

Editierbarkeit, Ausdrucksbedingungen, Read-only-Stil, Platzhalter, Passwortmodus,
Maximallänge, ARIA-Label/Pflichtkennzeichnung, Tab-Reihenfolge und Autocomplete
werden als Ruby-Seitenoptionen exportiert. Änderungen in `app/pages/**/*.rb`
wirken ohne MPR-Neukompilierung. Verschachtelte Data Views können eine gesperrte
übergeordnete View nicht entsperren. Unbekannte Bedingungen bleiben gesperrt;
Modulrollen werden gemeinsam mit unterstützten Ausdrücken geprüft. Backend-
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
Nach Quelländerungen die Anwendung neu laden. Anwendungen mit `runtime_model: ruby`
erkennen geladene Deklarationen und gleichen Löschungen und Umbenennungen ab.
Legacy-Einträge benötigen einen neuen Export. Das Manifest bleibt als private
Rekonstruktionsmetadaten erhalten; der Runtime-Katalog braucht keine manuelle Pflege.

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
