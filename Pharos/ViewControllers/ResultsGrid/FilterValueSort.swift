/// Which key the filter checklist is sorted by.
enum FilterValueSortField {
    case value
    case count
}

/// Pure ordering for the filter checklist. `values` must arrive in the canonical
/// type-aware ascending order; this reorders them for display. No AppKit.
enum FilterValueSort {
    static func ordered(_ values: [String],
                        counts: [String: FilterValueCount],
                        field: FilterValueSortField,
                        ascending: Bool) -> [String] {
        switch field {
        case .value:
            return ascending ? values : values.reversed()
        case .count:
            let index = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($1, $0) })
            return values.sorted { a, b in
                let fa = counts[a]?.filtered ?? 0
                let fb = counts[b]?.filtered ?? 0
                if fa != fb { return ascending ? fa < fb : fa > fb }
                let ta = counts[a]?.total ?? 0
                let tb = counts[b]?.total ?? 0
                if ta != tb { return ascending ? ta < tb : ta > tb }
                return (index[a] ?? 0) < (index[b] ?? 0)   // stable by original order
            }
        }
    }
}
