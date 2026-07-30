# Navegação e design system

**Português** · [English](../en-US/design-system.md) · [Deutsch](../de-DE/design-system.md)

Perfis são dados nativos Mendix. O MXRB lê e escreve home por página ou
microflow, login, título traduzido, ícone, home por papel e menus recursivos.

```ruby
navigation do
  profile :Responsive, home_page: "Sales.Home", app_title: "Loja" do
    title :en_US, "Shop"
    home_for :Administrator, microflow: "Sales.OpenDashboard"
    item "Pedidos", page: "Sales.Order_Overview", icon: "shopping_cart"
  end
end
```

`project.design_system` inventaria propriedades CSS, variáveis Sass, temas e
catálogos `design-properties.json`. O lint encontra tokens ausentes, cores
literais e contratos de contraste abaixo do nível WCAG declarado.

Themes, widgets, resources e fontes Java fazem round-trip por
`.mxrb/assets.json`, com SHA-256 e validação contra traversal.

Migrações de literais são preview-first:

```ruby
plan = project.plan_design_token_migration(
  "#3366ff" => "var(--brand-primary)"
)
plan.changes.each { puts "#{_1.path}: #{_1.occurrences}" }
plan.apply!
```

O apply rejeita arquivos alterados desde o preview e substitui cada arquivo
atomicamente.

[Voltar ao índice](README.md)
