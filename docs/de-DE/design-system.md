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
