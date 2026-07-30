# frozen_string_literal: true

require "spec_helper"
require "pathname"

RSpec.describe "localized documentation" do
  root = Pathname(__dir__).join("..").expand_path
  locales = %w[pt-BR en-US de-DE].freeze

  # Documents that must exist, with the same file names, in every locale.
  shared_documents = %w[
    README.md architecture.md architectural-standard.md
    project-structure.md architectural-patterns.md semantic-refactoring.md
    design-system.md conventions.md ruby-first-roadmap.md
    validation-matrix.md writing.md oql-sql.md
  ].sort.freeze

  it "keeps the same document set in every locale" do
    sets = locales.to_h do |locale|
      files = root.join("docs", locale).glob("*.md").map(&:basename).map(&:to_s).sort
      [locale, files]
    end

    expect(sets.fetch("pt-BR")).to eq(shared_documents), sets.inspect
    expect(sets.fetch("de-DE")).to eq(shared_documents), sets.inspect
    expect(sets.fetch("en-US")).to eq(shared_documents), sets.inspect
  end

  it "does not leave registered translation placeholders" do
    text = locales.flat_map { root.join("docs", _1).glob("*.md") }.map(&:read).join("\n")

    expect(text).not_to match(/translation pending|PENDING_TRANSLATION/)
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

  it "does not mix Portuguese prose into the English writing guide" do
    prose = root.join("docs", "en-US", "writing.md").read.lines.drop(3).join
    portuguese = /
      [ãõç]|
      \b(?:uma|mesmas|renomeação|escrita|plano|operação|acoplamento|
      relatório|regras|mudanças|navegação|idênticos|diferenças)\b
    /ix

    expect(prose).not_to match(portuguese)
  end
end
