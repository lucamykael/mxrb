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

  it "keeps only the language selector outside locale directories" do
    root_documents = root.join("docs").glob("*.md").map(&:basename).map(&:to_s)

    expect(root_documents).to eq(["README.md"])
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

  it "does not publish internal workflow or continuation instructions" do
    markdown = [
      root.glob("README*.md"),
      root.join("docs").glob("**/*.md")
    ].flatten
    patterns = [
      /\b(?:AI|IA|LLM)\b/i,
      /\b(?:agent|agente|prompt|handoff)\b/i,
      /ai[-_ ]?memory/i,
      /artificial intelligence|inteligência artificial|künstliche intelligenz/i,
      %r{\A[#]{1,6}\s+(?:next steps|próximas etapas|nächste schritte)\b}i,
      /\b(?:next layer|próxima camada|nächste ebene)\b/i,
      /\b(?:explicit next step|próximo passo explícito)\b/i
    ]
    matches = markdown.flat_map do |source|
      source.each_line.with_index(1).filter_map do |line, number|
        "#{source.relative_path_from(root)}:#{number}: #{line.strip}" \
          if patterns.any? { line.match?(_1) }
      end
    end

    expect(matches).to be_empty, "AI traces found:\n#{matches.join("\n")}"
  end
end
