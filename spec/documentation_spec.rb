# frozen_string_literal: true

require "spec_helper"
require "pathname"

RSpec.describe "localized documentation" do
  root = Pathname(__dir__).join("..").expand_path
  locales = %w[pt-BR en-US de-DE].freeze

  # Documents that must exist, with the same file names, in every locale.
  shared_documents = %w[
    README.md architecture.md architectural-standard.md
    ruby-first-roadmap.md validation-matrix.md writing.md
  ].sort.freeze

  # English-first documents that are allowed to exist only under docs/en-US.
  # Every entry here is a promise to translate it, not a loophole.
  # TODO: write the pt-BR and de-DE versions of each page listed below and
  # then move it into SHARED_DOCUMENTS:
  # - docs/pt-BR/project-structure.md      and docs/de-DE/project-structure.md
  # - docs/pt-BR/architectural-patterns.md and docs/de-DE/architectural-patterns.md
  # - docs/pt-BR/semantic-refactoring.md   and docs/de-DE/semantic-refactoring.md
  # - docs/pt-BR/design-system.md          and docs/de-DE/design-system.md
  # - docs/pt-BR/conventions.md            and docs/de-DE/conventions.md
  pending_translation = %w[
    project-structure.md architectural-patterns.md semantic-refactoring.md
    design-system.md conventions.md
  ].sort.freeze

  it "keeps the same document set in every locale" do
    sets = locales.to_h do |locale|
      files = root.join("docs", locale).glob("*.md").map(&:basename).map(&:to_s).sort
      [locale, files]
    end

    expect(sets.fetch("pt-BR")).to eq(shared_documents), sets.inspect
    expect(sets.fetch("de-DE")).to eq(shared_documents), sets.inspect
    expect(sets.fetch("en-US")).to eq((shared_documents + pending_translation).sort), sets.inspect
  end

  it "keeps pending-translation pages registered and out of other locales" do
    en_us = root.join("docs", "en-US").glob("*.md").map(&:basename).map(&:to_s)

    unregistered = en_us - shared_documents - pending_translation
    expect(unregistered).to be_empty,
                            "unregistered en-US-only pages: #{unregistered.join(', ')}; " \
                            "add them to PENDING_TRANSLATION with a translation TODO " \
                            "or translate them into every locale"

    %w[pt-BR de-DE].each do |locale|
      leaked = root.join("docs", locale)
                   .glob("*.md").map(&:basename).map(&:to_s) & pending_translation
      expect(leaked).to be_empty,
                        "#{locale} contains pages registered as pending translation: " \
                        "#{leaked.join(', ')}; remove the placeholder or drop the " \
                        "entry from PENDING_TRANSLATION"
    end
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
