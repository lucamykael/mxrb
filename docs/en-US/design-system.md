# Navigation and design system

[Português](../pt-BR/design-system.md) · **English** · [Deutsch](../de-DE/design-system.md)

Navigation and design-system round trips are part of the current typed
surface. Native profiles, filesystem assets and design-token quality tooling
are covered by the public test and fixture matrix.

## Native navigation

A Mendix navigation document is read as typed Ruby through
`project.navigation`:

```ruby
Mxrb.open("app.mpr") do |project|
  project.navigation.profiles.each do |profile|
    puts "#{profile.name} (#{profile.kind})"
    puts "  home page:      #{profile.home_page}"
    puts "  home microflow: #{profile.home_microflow}"
    puts "  sign-in page:   #{profile.sign_in_page}"
    puts "  app title:      #{profile.app_title}" # { "en_US" => "...", "nl_NL" => "..." }

    profile.role_homes.each do |home|
      puts "  #{home[:role]} -> #{home[:page] || home[:microflow]}"
    end

    profile.menu_items.each do |item|
      puts "  #{item[:caption]} -> #{item[:page] || item[:microflow]}"
    end
  end
end
```

Coverage and behavior:

- Modern `Profiles` and the legacy Mendix 5/6 profile documents
  (`DesktopProfile`, `PhoneProfile`, `TabletProfile`, hybrid and offline
  variants) are normalized into the same `NavigationProfile` objects.
- Home pages per role, nested menu trees, icons and caption translations are
  exposed as plain Ruby data.
- `offline?` flags offline-capable profiles.
- Navigation references participate in the semantic index, so
  `references_from`, rename and remove plans already account for navigation
  targets.

The same structures can be declared in the Ruby DSL and written back to the
native navigation document. Rename, remove, diff and lint operate on those
references, including user-role access to role-specific homes.

## Design tokens from real stylesheets

`project.design_system` scans the project directory (`theme/`,
`themesource/`, `resources/`, `widgets/`, `javasource/`,
`javascriptsource/`) for CSS custom properties and SCSS variables:

```ruby
design = project.design_system

design.tokens.each do |token|
  puts "#{token.name}: #{token.value} (#{token.kind}, #{token.path}:#{token.line})"
end

design.themes        # theme names derived from _theme-<name>.scss files
design.catalogs      # themesource/**/design-properties.json contents
```

Each `DesignToken` is an immutable value with `name`, `value`, `kind`
(`:css_custom_property` or `:scss_variable`), `theme`, `path` and `line`.

## Guidelines the tooling enforces

### Prefer tokens over literals

Hard-coded colors scattered through stylesheets drift out of sync with the
theme. `literal_colors` lists tokens whose values are raw hex colors, and
`unresolved_references` lists `var(--x)` references that point to a token
that does not exist:

```ruby
design.literal_colors
design.unresolved_references.each do |issue|
  puts "#{issue[:reference]} used by #{issue[:token].name} is undefined"
end
```

### Check accessibility contrast

`contrast_ratio` computes the WCAG luminance ratio between two hex colors:

```ruby
design.contrast_ratio("#777777", "#ffffff") # => 4.48
```

Ratios of at least 4.5 are the common baseline for normal text (7 for the
enhanced level); the method returns the number so projects can assert their
own thresholds in evaluations or lint rules.

### Migrate literals with preview and safe apply

Literal replacement follows the same plan / preview / `apply!` discipline as
semantic refactoring:

```ruby
plan = project.plan_design_token_migration("#777777" => "var(--color-foreground)")

plan.changes.each do |change|
  puts "#{change.path}: #{change.occurrences} occurrence(s)"
end

plan.apply!
```

Guarantees:

- every change lists its file, before/after contents and occurrence count;
- `apply!` re-checks each file's SHA-256 against the preview and raises
  `SerializationError` if a file changed meanwhile — a stale preview is never
  written;
- each file is written through a temporary file plus atomic rename;
- a plan applies once; re-applying raises.

## Themes, resources and unknown structures

Themes, images, widgets, resources and Java sources are copied through
`.mxrb/assets.json`. Every entry has a relative path, size and SHA-256 digest;
reconstruction rejects traversal, missing files and checksum mismatches.
Unknown model units remain in the lossless native baseline.

## Validation status

The typed navigation writer, asset manifest, contrast/literal lint and atomic
migration are implemented. Structural round trips pass the six-fixture matrix,
including modern `Profiles` and preserved legacy navigation shapes. See the
[validation matrix](validation-matrix.md) for the current evidence.
