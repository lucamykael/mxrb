# Navigation and design system

**English** · translation pending — see `PENDING_TRANSLATION` in
`spec/documentation_spec.rb`

> Status: incremental construction. The navigation document reader and the
> design-token tooling described below exist in the current codebase and are
> covered by tests, while the full native round trip (writing navigation
> profiles and design properties back into Mendix documents) is still being
> built. As with every MXRB surface, structures without a typed writer remain
> preserved losslessly in the native baseline — nothing is dropped while the
> typed API grows.

This page describes the native navigation and design-system direction: what
works today, the guidelines the typed APIs are built around, and what is
planned. It follows the same Ruby-first principles as the rest of the
toolkit.

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

Planned increments: typed writing of profiles, home pages per role, menus and
translations back into the native document, with references kept consistent
across rename/move/remove and diff/lint. Until then the baseline keeps the
original document intact.

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

Mendix themes, images and design properties that do not yet have a typed
Ruby API remain in the lossless native baseline and can still be edited as
deep Ruby hashes through `.mxrb/native_units.rb`. That is the standing MXRB
rule: preservation first, concise typed APIs second, never data loss in
between.

## Roadmap

Framed as incremental work, in rough order:

1. Typed writing of navigation profiles, role home pages, menus and
   translations, integrated with rename/move/remove, diff and lint.
2. Native design properties and tokens as first-class DSL declarations, with
   themes and CSS/SCSS output generated from semantic Ruby intent.
3. Deeper accessibility checks and literal detection wired into lint rules.
4. Atomic design migration with rollback composed into batch plans.
5. Fixtures and multi-version matrix evidence for navigation and design
   round trips.

The [Ruby-first roadmap](ruby-first-roadmap.md) tracks these against the
rest of the planned surface.
