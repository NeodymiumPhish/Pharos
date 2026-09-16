import Foundation
import CPharosCore

// MARK: - Query variables (the app-wide `{{name}}` list)
//
// Swift side of pharos-core/src/ffi/query_variables.rs. The list is GLOBAL —
// one for every window, tab and connection — so neither call takes a key.
//
// The JSON keys are `QueryVariable.CodingKeys` verbatim (`id`, `name`, `value`,
// `type`); the Rust struct renames its `kind` field to `type` to match, and
// `JSONEncoder.pharos` / `JSONDecoder.pharos` apply NO key strategy. Do not add
// one here.

extension PharosCore {

    /// Every stored variable, in the user's order. An empty array is the
    /// normal first answer: the list starts empty.
    static func loadQueryVariables() throws -> [QueryVariable] {
        try callSync { pharos_load_query_variables() }
    }

    /// Replace the stored list. The array order becomes the stored order.
    static func saveQueryVariables(_ variables: [QueryVariable]) throws {
        try callSyncVoid(input: variables) { pharos_save_query_variables($0) }
    }
}
