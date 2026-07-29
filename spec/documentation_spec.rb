# frozen_string_literal: true

require "spec_helper"
require "pathname"

RSpec.describe "localized documentation" do
  root = Pathname(__dir__).join("..").expand_path
  locales = %w[pt-BR en-US de-DE].freeze

  it "keeps the same document set in every locale" do
    sets = locales.to_h do |locale|
      files = root.join("docs", locale).glob("*.md").map(&:basename).map(&:to_s).sort
      [locale, files]
    end

    expect(sets.values.uniq.size).to eq(1), sets.inspect
    expect(sets.values.first).to eq(
      %w[
        README.md architecture.md architectural-standard.md
        ruby-first-roadmap.md validation-matrix.md writing.md
      ].sort
    )
  end

  it "does not contain broken relative Markdown links" do
    markdown = [
      root.glob("README*.md"),
      root.join("docs").glob("**/*.md")
    ].flatten.reject { _1.basename.to_s == "AI_MEMORY_HANDOFF.md" }

    broken = markdown.flat_map do |source|
      source.read.scan(/\[[^\]]+\]\(([^)]+)\)/).filter_map do |match|
        target = match.first.split("#", 2).first
        next if target.empty? || target.match?(/\A(?:https?:|mailto:)/)

        resolved = source.dirname.join(target).cleanpath
        "#{source.relative_path_from(root)} -> #{target}" unless resolved.exist?
      end
    end

    expect(broken).to be_empty, "broken documentation links:\n#{broken.join("\n")}"
  end
end
