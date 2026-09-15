import AppKit
import Foundation

// MARK: - Connection Colour

/// The fixed set of colours a connection can be labelled with.
///
/// A fixed palette rather than a free colour picker, for three reasons: the
/// label has to stay legible as a 10pt dot in a menu and as a 3pt band over an
/// editor, it has to have a NAME so the same signal can be given as text under
/// Differentiate Without Color, and a stored hex from a picker would drift with
/// every re-pick of "the same" colour.
///
/// The hex values are frozen sRGB, not `NSColor.system*`: the system colours
/// are dynamic and resolve differently in light and dark, so a hex read back
/// from one would not equal the hex that was stored. Stored hex and drawn
/// swatch agree because both come from the constant below.
enum ConnectionColor: String, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var hex: String {
        switch self {
        case .red:    return "#FF3B30"
        case .orange: return "#FF9500"
        case .yellow: return "#FFCC00"
        case .green:  return "#28CD41"
        case .teal:   return "#59ADC4"
        case .blue:   return "#007AFF"
        case .purple: return "#AF52DE"
        case .pink:   return "#FF2D55"
        }
    }

    var displayName: String {
        switch self {
        case .red:    return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .teal:   return "Teal"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        case .pink:   return "Pink"
        }
    }

    var color: NSColor { Self.color(forHex: hex) ?? .clear }

    static func named(forHex hex: String?) -> ConnectionColor? {
        guard let hex else { return nil }
        return allCases.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    /// A stored hex as a colour. Any well-formed `#RRGGBB` resolves, not only
    /// the eight: a record carrying a colour from elsewhere still shows it.
    static func color(forHex hex: String?) -> NSColor? {
        guard let hex, let rgb = ChartPalette.rgb(fromHex: hex) else { return nil }
        return NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                       blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// The colour's name where it has one, and the hex itself where it does
    /// not — for tooltips and accessibility labels, which must say something.
    static func label(forHex hex: String?) -> String? {
        guard let hex else { return nil }
        return named(forHex: hex)?.displayName ?? (ChartPalette.rgb(fromHex: hex) != nil ? hex : nil)
    }

    /// A filled circle, for a menu item's image. `nil` for no colour, so the
    /// caller can assign it straight through.
    static func swatchImage(forHex hex: String?, diameter: CGFloat = 10) -> NSImage? {
        guard let color = color(forHex: hex) else { return nil }
        let size = NSSize(width: diameter, height: diameter)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// Black or white, whichever reads on `hex`. Used by the editor band's
    /// name, which sits ON the colour.
    static func foreground(onHex hex: String?) -> NSColor {
        guard let rgb = ChartPalette.rgb(fromHex: hex ?? "") else { return .labelColor }
        // Rec. 601 luma — close enough for a two-way choice, and stable
        // whatever appearance the app is in.
        let luma = (0.299 * Double(rgb.r) + 0.587 * Double(rgb.g) + 0.114 * Double(rgb.b)) / 255
        return luma > 0.6 ? .black : .white
    }
}

// MARK: - Connection Config

enum SslMode: String, Codable {
    case disable
    case prefer
    case require
}

struct ConnectionConfig: Codable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var database: String
    var username: String
    var password: String = ""
    var sslMode: SslMode = .prefer
    var color: String?
    var defaultSchema: String?

    /// Ask the device owner to authenticate (Touch ID, Apple Watch or the login
    /// password) before connecting with this record and before showing its
    /// stored password.
    ///
    /// The gate guards the two places the app ACTS on the password; it does not
    /// change where the password lives. The Keychain item is written and read
    /// exactly as before, so anything else on the machine that can read that
    /// item still can. The flag buys a shoulder-surfing and walk-up barrier, not
    /// storage protection.
    var requiresAuthentication: Bool = false

    // Custom decoder: Rust skips "password" when empty and "color" when nil,
    // so these keys may be absent in the JSON.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        database = try c.decode(String.self, forKey: .database)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        sslMode = try c.decodeIfPresent(SslMode.self, forKey: .sslMode) ?? .prefer
        color = try c.decodeIfPresent(String.self, forKey: .color)
        defaultSchema = try c.decodeIfPresent(String.self, forKey: .defaultSchema)
        // `decodeIfPresent`, so a record written before the column existed —
        // and any producer that still omits the key — reads back ungated.
        requiresAuthentication = try c.decodeIfPresent(Bool.self, forKey: .requiresAuthentication) ?? false
    }

    init(id: String, name: String, host: String, port: UInt16, database: String,
         username: String, password: String = "", sslMode: SslMode = .prefer,
         color: String? = nil, defaultSchema: String? = nil,
         requiresAuthentication: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.sslMode = sslMode
        self.color = color
        self.defaultSchema = defaultSchema
        self.requiresAuthentication = requiresAuthentication
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, password, sslMode, color, defaultSchema
        case requiresAuthentication
    }
}

// MARK: - Equality (drives the connections form's dirty state)

extension ConnectionConfig: Equatable {
    public static func == (a: ConnectionConfig, b: ConnectionConfig) -> Bool {
        a.id == b.id && a.name == b.name && a.host == b.host && a.port == b.port
            && a.database == b.database && a.username == b.username
            && a.password == b.password && a.sslMode == b.sslMode
            && a.color == b.color && a.defaultSchema == b.defaultSchema
            && a.requiresAuthentication == b.requiresAuthentication
    }
}

// MARK: - Connection Status

enum ConnectionStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case error
}

struct ConnectionInfo: Codable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let database: String
    let status: ConnectionStatus
    let error: String?
    let latencyMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, status, error
        case latencyMs = "latency_ms"
    }
}

struct TestConnectionResult: Codable {
    let success: Bool
    let latencyMs: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, error
        case latencyMs = "latency_ms"
    }
}
