# frozen_string_literal: true

# First functional slice: each microflow must complete without an unhandled
# runtime exception. The source project is never modified.
microflow "creates an easy game",
          call: "Sudoku.ACT_NewEasy",
          expect: {
            count: [
              { entity: "Sudoku.Game", equals: 1 },
              { entity: "Sudoku.Cell", equals: 81 }
            ]
          }
microflow "creates a medium game",
          call: "Sudoku.ACT_NewMedium",
          expect: {
            count: [
              { entity: "Sudoku.Game", equals: 2 },
              { entity: "Sudoku.Cell", equals: 162 }
            ]
          }
microflow "creates a hard game",
          call: "Sudoku.ACT_NewHard",
          expect: {
            count: [
              { entity: "Sudoku.Game", equals: 3 },
              { entity: "Sudoku.Cell", equals: 243 }
            ]
          }
