import Foundation

/// How to tell the user about a failure that happened away from their attention.
///
/// Pure on purpose: the choice depends only on app state and two settings, so a
/// test reaches it without AppKit or UserNotifications.
enum QueryFailureChannel: Equatable {

    /// Say nothing. The sheet is already in front of the user, or the user turned
    /// these alerts off.
    case none

    /// A `Toast` inside the window. It leaves nothing in Notification Center.
    case inAppBanner

    /// A system notification, taken out of Notification Center after the banner
    /// has left the screen.
    case systemBanner

    /// - Note: the minimum-duration setting has no part in this choice. That gate
    ///   exists to keep fast, successful queries quiet, and a failure usually
    ///   returns in far less than its 5 s default, so applying it would hide
    ///   almost every failure.
    static func choose(
        appInactive: Bool,
        isBackgroundTab: Bool,
        notifyWhenAppInactive: Bool,
        notifyWhenBackgroundTab: Bool
    ) -> QueryFailureChannel {
        let inactiveAllows = notifyWhenAppInactive && appInactive
        let backgroundAllows = notifyWhenBackgroundTab && isBackgroundTab
        guard inactiveAllows || backgroundAllows else { return .none }
        // A banner inside the window cannot be seen when Pharos is not in front.
        return appInactive ? .systemBanner : .inAppBanner
    }
}
