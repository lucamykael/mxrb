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

Themes, Widgets, Ressourcen und Java-Quellen durchlaufen den Round-trip über
`.mxrb/assets.json` mit SHA-256 und Traversal-Schutz.

Literale Migrationen beginnen mit einer Vorschau. Apply lehnt Dateien ab, die
sich seit der Vorschau geändert haben, und ersetzt jede Datei atomar.

[Zurück zum Index](README.md)
