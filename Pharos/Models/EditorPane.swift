import Foundation

/// Represents an independent editor pane, each with its own set of tabs.
/// Multiple panes can exist side-by-side in the editor area.
struct EditorPane: Identifiable {
    let id: String
    var tabIds: [String]          // Ordered tab IDs in this pane
    var activeTabId: String?      // Currently selected tab within this pane
    var isExpanded: Bool = false   // When true, fills the entire editor area

    init(id: String = UUID().uuidString, tabIds: [String] = [], activeTabId: String? = nil) {
        self.id = id
        self.tabIds = tabIds
        self.activeTabId = activeTabId
    }
}
