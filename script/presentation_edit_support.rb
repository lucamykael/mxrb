# frozen_string_literal: true

module PresentationEditCertification
  # Independent expected-model edits and strict source replacement checks.
  module NativeEdits
    def within(root, relative)
      base = File.realpath(root)
      path = File.realpath(File.join(base, relative))
      raise ArgumentError, "path outside workspace: #{relative}" unless path.start_with?("#{base}/")

      path
    end

    def documents(project)
      project.modules.flat_map do |mod|
        pages = mod.pages.map { [_1.id, _1.name, _1.raw_document] }
        shared = mod.presentation_documents.map { _1.values_at(:id, :name, :doc) }
        (pages + shared).map { |id, name, document| ["#{mod.name}.#{name}", [id, document]] }
      end.to_h
    end

    def named_widgets(value, name, found = [])
      case value
      when Hash
        found << value if value['Name'] == name && value['$Type'].to_s.start_with?('Forms$', 'Pages$')
        value.each_value { named_widgets(_1, name, found) }
      when Array then value.each { named_widgets(_1, name, found) }
      end
      found
    end

    def field_owner(document, edit)
      if edit['widget']
        matches = named_widgets(document, edit.fetch('widget'))
        raise ArgumentError, "ambiguous or missing widget #{edit['widget']}" unless matches.one?

        document = matches.first
      end
      path = edit.fetch('field')
      [path[0...-1].reduce(document) { |value, key| value.fetch(key) }, path.last]
    end

    def edit_expected(path, edits)
      Mxrb.open(path, readonly: false) do |project|
        entries = documents(project)
        targets(edits).map { apply_native_edit(project, entries, _1) }
      end
    end

    def targets(edits)
      edits.flat_map do |edit|
        fields = edit.fetch('fields') { [edit.fetch('field')] }
        fields.map { edit.merge('field' => _1) }
      end
    end

    def apply_native_edit(project, entries, edit)
      id, document = entries.fetch(edit.fetch('unit'))
      owner, key = field_owner(document, edit)
      before = owner.fetch(key)
      after = edit.fetch('value')
      raise ArgumentError, 'expected edit must change its value' if before == after

      owner[key] = after
      project.mpr.update_unit(id, document)
      { unit: edit.fetch('unit'), kind: edit.fetch('kind'), field: edit.fetch('field'), before:, after: }
    end

    def edit_ruby(root, edits)
      edits.each do |edit|
        path = within(root, edit.fetch('file'))
        source = File.read(path)
        from = edit.fetch('from')
        if from.empty? || source.scan(from).size != 1
          raise ArgumentError,
                "edit must match exactly once: #{edit['file']}"
        end

        File.write(path, source.sub(from) { edit.fetch('to') })
      end
    end

    def verify_values(path, edits)
      Mxrb.open(path) do |project|
        entries = documents(project)
        targets(edits).each do |edit|
          _id, document = entries.fetch(edit.fetch('unit'))
          owner, key = field_owner(document, edit)
          raise "native edit missing: #{edit['unit']} #{edit['field']}" unless owner.fetch(key) == edit.fetch('value')
        end
      end
    end

    def assert_identical(left, right)
      validation = Mxrb.validate(right)
      raise validation.errors.join("\n") unless validation.valid?

      comparison = Mxrb.compare(left, right)
      raise comparison.differences.first(10).join("\n") unless comparison.identical?
    end
  end
end
