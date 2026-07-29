# frozen_string_literal: true

# Executable model expectations: plain Ruby, no MDL.
artifact "Sudoku.Game", kind: :entity
artifact "Sudoku.Game_Play", kind: :page
artifact "Sudoku.ACT_DealGame", kind: :microflow

no_call_cycles
no_missing_internal_references
maximum_unreferenced 250, severity: :warning

check "Sudoku exposes its three domain entities" do |project|
  project.search_artifacts("Sudoku.", kind: :entity).size == 3
end
