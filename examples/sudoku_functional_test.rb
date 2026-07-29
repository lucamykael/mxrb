# frozen_string_literal: true

# First functional slice: each microflow must complete without an unhandled
# runtime exception. The source project is never modified.
microflow "creates an easy game", call: "Sudoku.ACT_NewEasy"
microflow "creates a medium game", call: "Sudoku.ACT_NewMedium"
microflow "creates a hard game", call: "Sudoku.ACT_NewHard"
