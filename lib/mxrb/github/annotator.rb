# frozen_string_literal: true

require "json"
require "open3"

module Mxrb
  module Github
    # Maps a Compare::Result to GitHub annotations.
    #
    # Supports two output modes:
    #   1. GitHub Actions workflow commands (stdout lines) for CI annotation
    #   2. `gh pr comment` for pull request review comments
    #
    # Usage:
    #   result = Mxrb::Compare::Comparator.new(base_mpr, head_mpr).compare
    #   ann = Mxrb::Github::Annotator.new(result, exported_dir: "out/", repo: "org/repo")
    #   ann.print_actions_annotations          # write to stdout for GH Actions
    #   ann.post_pr_comment!(pr_number: 42)   # post summary via gh CLI
    class Annotator
      # Maps Compare path segments to file-layer hints used in exported trees.
      LAYER_MAP = {
        "entities"   => "domain",
        "attributes" => "domain",
        "microflows" => "logic",
        "nanoflows"  => "presentation",
        "pages"      => "presentation",
        "menus"      => "presentation",
      }.freeze

      Annotation = Data.define(:level, :title, :message, :file, :line)

      def initialize(compare_result, exported_dir: nil, repo: nil)
        @result       = compare_result
        @exported_dir = exported_dir && File.expand_path(exported_dir)
        @repo         = repo
      end

      # Returns an array of Annotation structs for each changed artifact.
      def annotations
        @annotations ||= @result.changes.map do |change|
          build_annotation(change)
        end
      end

      # Emits GitHub Actions workflow command lines to stdout.
      # When run inside a GH Actions job these create inline PR annotations.
      def print_actions_annotations(out: $stdout)
        annotations.each do |ann|
          file_part = ann.file ? "file=#{ann.file}" : ""
          line_part = ann.line ? ",line=#{ann.line}" : ""
          out.puts "::#{ann.level} #{file_part}#{line_part},title=#{ann.title}::#{ann.message}"
        end
      end

      # Posts a Markdown summary comment to a GitHub PR via the `gh` CLI.
      def post_pr_comment!(pr_number:, repo: @repo)
        raise ArgumentError, "repo required (org/name)" unless repo
        raise ArgumentError, "pr_number required" unless pr_number

        body = build_comment_body
        cmd  = ["gh", "pr", "comment", pr_number.to_s, "--repo", repo, "--body", body]
        out, err, status = Open3.capture3(*cmd)
        raise "gh pr comment failed: #{err}" unless status.success?

        out.strip
      end

      # Returns the comment body Markdown string without posting it.
      def comment_body
        build_comment_body
      end

      private

      def build_annotation(change)
        op    = change.operation
        path  = change.path
        label = path.last.to_s
        module_name = infer_module(change)

        level   = op == :removed ? "warning" : (op == :added ? "notice" : "notice")
        title   = "#{op.to_s.capitalize}: #{label}"
        message = format_message(change)
        file    = exported_file(path, module_name)
        line    = find_line_in_file(file, label)

        Annotation.new(level: level, title: title, message: message, file: file, line: line)
      end

      def format_message(change)
        op = change.operation
        path = change.path.join(" › ")
        case op
        when :added   then "Added: #{path}"
        when :removed then "Removed: #{path}"
        when :changed
          before = change.before.inspect
          after  = change.after.inspect
          "Changed: #{path} (#{before} → #{after})"
        end
      end

      def infer_module(change)
        @result.changes.each do |c|
          next unless c.path.first == "modules" && c.path.size > 1
          return c.path[1] if change.path.join.include?(c.path[1].to_s)
        end
        nil
      end

      def exported_file(path, module_name)
        return nil unless @exported_dir && module_name

        layer = LAYER_MAP[path.first.to_s]
        return nil unless layer

        artifact_name = path.last.to_s.downcase
        case layer
        when "domain"
          File.join(@exported_dir, "modules", module_name, "domain", "model.rb")
        when "logic"
          File.join(@exported_dir, "modules", module_name, "logic", "#{artifact_name}.rb")
        when "presentation"
          File.join(@exported_dir, "modules", module_name, "presentation", "#{artifact_name}.rb")
        end
      end

      def find_line_in_file(file, label)
        return nil unless file && File.file?(file.to_s)

        File.each_line(file).with_index(1) do |line, n|
          return n if line.include?(label)
        end
        nil
      end

      def build_comment_body
        lines = ["## MXRB Semantic Diff\n"]
        lines << "| Operation | Artifact | Detail |"
        lines << "|-----------|----------|--------|"

        @result.changes.each do |change|
          op    = change.operation.to_s.capitalize
          path  = change.path.join(" › ")
          detail = case change.operation
                   when :changed then "`#{change.before}` → `#{change.after}`"
                   else ""
                   end
          icon = { added: "✅", removed: "❌", changed: "✏️" }[change.operation] || "ℹ️"
          lines << "| #{icon} #{op} | `#{path}` | #{detail} |"
        end

        lines << ""
        lines << "_Generated by [MXRB](https://github.com/lucamykael/mxrb)_"
        lines.join("\n")
      end
    end
  end
end
