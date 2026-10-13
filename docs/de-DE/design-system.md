# Navigation und Design System

[Português](../pt-BR/design-system.md) · [English](../en-US/design-system.md) · **Deutsch**

Navigationsprofile sind native Mendix-Daten. MXRB liest und schreibt
Standardseiten oder -Microflows, Login-Seiten, übersetzte Titel, Symbole,
rollenspezifische Ziele und rekursive Menüs.

```ruby
navigation do
  profile :Responsive, home_page: "Sales.Home", app_title: "Shop" do
    title :de_DE, "Geschäft"
    home_for :Administrator, microflow: "Sales.OpenDashboard"
    item "Bestellungen", page: "Sales.Order_Overview", icon: "shopping_cart"
  end
end
```

Unterstützte Profileinstellungen umfassen außerdem den älteren
`enabled`-/`offline_enabled`-Status, übersetzte Login-Titel, die ältere
Login-Position, Not-found-Seiten oder -Microflows sowie
`throw_partial_sync_error`. Änderungen behalten native und verschachtelte IDs
bei. Noch nicht dargestellte PWA- und Offline-Konfigurationen bleiben opak und
unverändert.

## Native Mobile-Profile

Ein `Navigation$NativeNavigationProfile` wird mit `kind: "Native"` gelesen.
Es hat eine native Startseite oder einen Nanoflow, rollenspezifische
Startseiten und Einträge der unteren Navigationsleiste. Dazu kommen die
Einstellungen für OTA, Logging, Verschlüsselung, Übergänge, Netzwerk-Timeout
und native Navigation. Ein Webmenü, ein Titel und eine Login-Seite fehlen.
Der Writer erzeugt und führt das native Dokument zusammen, nie die Felder
eines Webprofils.

```ruby
navigation do
  profile :NativePhone, kind: "Native", home_page: "Field.Home",
                        settings: { ota_enabled: true, network_timeout_ms: 30_000 } do
    home_for :Inspector, page: "Field.Inspections", nanoflow: nil
    bottom_bar_item "Home", page: "Field.Home", icon: { collection: "Atlas_Core.Atlas_Filled.home" }
    bottom_bar_item "Inspections", page: "Field.Inspections", translations: { pt_BR: "Inspeções" }
  end
end
```

```ruby
module Field
  class TasksPage < Mxrb::RubyApp::Page
    mendix_name "Field.Tasks"
    native do
      layout "Atlas_Core.NativePhone_Default"
      title "Tasks"
      text :Heading, caption: "Tasks"
    end
    navigation caption: "Tasks", profile: "NativePhone"
  end
end
```

Im Ruby-Modus ergänzt oder aktualisiert `navigation profile: "NativePhone"`
auf einer `native`-Seite deren Eintrag in der unteren Navigationsleiste. Mit
`home: true` wird die Seite außerdem zur nativen Startseite. Unbekannte
Einstellungen scheitern beim Auswerten der DSL. Zertifiziert wurde mit einer
Sudoku-Kopie, die Studio Pro 11.12.1 mit nativem Profil gespeichert hat. Die
in Ruby deklarierte native Seite und ihr Eintrag bestanden `mx check` und
Studio Pro mit 0 Fehlern.

`project.design_system` inventarisiert CSS-Eigenschaften, Sass-Variablen,
Themes und `design-properties.json`-Kataloge. Lint findet fehlende Tokens,
literale Farben und Kontrastverträge unterhalb des deklarierten WCAG-Niveaus.

In der Ruby-DSL deklarierte Tokens werden in
`theme/web/_mxrb-design-system.scss` materialisiert und genau einmal aus
`theme/web/main.scss` importiert. Farb-Tokens erscheinen zusätzlich als
Studio-`ColorPicker`-Eigenschaften in
`themesource/mxrb/web/design-properties.json`. Theme-Vererbung und Overrides
werden vor dem Schreiben aufgelöst; bestehender `main.scss`-Inhalt bleibt
erhalten. Zyklen, ungültige Namen und strukturell unsichere CSS-Werte werden
abgelehnt.

Themes, Widgets, Ressourcen und Java-Quellen durchlaufen den Round-trip über
`.mxrb/assets.json` mit SHA-256 und Traversal-Schutz.

Literale Migrationen beginnen mit einer Vorschau. Apply lehnt Dateien ab, die
sich seit der Vorschau geändert haben, und ersetzt jede Datei atomar.

Dieselben Abläufe stehen über die CLI zur Verfügung:

```sh
bundle exec mxrb design scan App.mpr
bundle exec mxrb design scan App.mpr --json
bundle exec mxrb design migrate App.mpr '#3366ff' 'var(--brand-primary)'
bundle exec mxrb design migrate App.mpr '#3366ff' 'var(--brand-primary)' --apply
```

`scan` zeigt Name, Wert, Typ, Theme und Quellposition jedes Tokens sowie die
Anzahl literaler Farben und nicht aufgelöster Referenzen. `migrate` bleibt bis
zur Angabe von `--apply` eine Vorschau. Im Ruby-Vertrag deklarierte
Kontrastpaare prüft `mxrb lint` gegen die konfigurierte WCAG-Stufe.

[Zurück zum Index](README.md)
