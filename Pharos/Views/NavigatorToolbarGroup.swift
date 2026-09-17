import AppKit

/// The grouped capsule in the toolbar that picks which navigator the sidebar
/// shows — the control Xcode uses for Navigators / Coding Assistant and
/// Calendar uses for Calendars / Invites.
///
/// A factory, not a view, for two reasons. It keeps `MainToolbarController`
/// free of construction detail, and it can be compiled on its own by
/// `scripts/test-sidebar-navigator.sh`: that suite runs plain `swiftc`, and
/// the toolbar controller cannot go through it because it pulls in the
/// PharosCore FFI bridge.
///
/// Why the convenience constructor and not `init(itemIdentifier:)` plus
/// hand-built `subitems`: `NSToolbarItemGroup.h` says of `selectionMode`
/// "Only applies when using one of the constructors to create the item with a
/// system defined control representation." The whole lit/unlit behaviour
/// rests on that property, so the manual path is not an option.
enum NavigatorToolbarGroup {

    static let identifier = NSToolbarItem.Identifier("PharosNavigator")

    /// `NSToolbarItemGroupRoleTabs`, spelled out because the enum itself is
    /// absent from the macOS 26 SDK. See the `role` note in `make`.
    private static let tabsRole = 1

    /// Builds the group. `action` is sent with the group as the sender; read
    /// `selectedIndex` from it to learn which segment was pressed.
    static func make(target: AnyObject?, action: Selector) -> NSToolbarItemGroup {
        let images = Navigator.allCases.map { navigator in
            NSImage(systemSymbolName: navigator.symbolName,
                    accessibilityDescription: navigator.title)
                ?? NSImage()
        }

        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: images,
            selectionMode: .selectOne,
            // The toolbar is `.iconOnly`, so per-segment labels would never be
            // drawn; the titles below carry the same text to AX and tooltips.
            labels: nil,
            target: target,
            action: action
        )

        // `.expanded` is required, not preferred. Measured live: with
        // `.automatic` the toolbar decides the sidebar region (traffic lights
        // to the tracking separator, ~108pt at the default 200pt sidebar) is
        // too tight and falls back to `.collapsed` — which is a pull-down menu
        // reading "Query Library", not a capsule at all. The sidebar's
        // minimumThickness is raised to match (PharosSplitViewController).
        group.controlRepresentation = .expanded

        // The semantic role for exactly this control. `role` is macOS 27 only
        // and the deployment target is 26.0, so a guard is load-bearing — but
        // it is set through the runtime, not as `group.role = .tabs`, because
        // `#available` is a run-time test and the symbol must also exist at
        // compile time. The release runner (`macos-26`) tops out at Xcode 26.6,
        // whose SDK has no `NSToolbarItemGroup.role`, so the direct form breaks
        // the build there. `NSToolbarItemGroupRoleTabs` is 1, and `responds(to:)`
        // is the real gate: it is false on every system that lacks the property.
        let setRole = Selector(("setRole:"))
        if group.responds(to: setRole) {
            group.setValue(Self.tabsRole, forKey: "role")
        }

        // Set on the parent item: what Customize Toolbar… shows, and what the
        // overflow menu falls back to.
        group.label = String(localized: "Navigators")
        group.paletteLabel = String(localized: "Navigators")

        for (index, navigator) in Navigator.allCases.enumerated()
        where index < group.subitems.count {
            let subitem = group.subitems[index]
            subitem.label = navigator.title
            subitem.paletteLabel = navigator.title
            subitem.toolTip = navigator.title
        }

        return group
    }

    /// The navigator a `selectedIndex` names, or nil when nothing is selected
    /// (the group reports -1 for that).
    static func navigator(forSelectedIndex index: Int) -> Navigator? {
        Navigator(rawValue: index)
    }
}
