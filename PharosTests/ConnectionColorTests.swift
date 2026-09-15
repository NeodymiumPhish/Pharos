// Standalone test for ConnectionColor — the connection colour label's fixed
// palette, its hex round-trip, and the two derived values the UI draws with.
import AppKit
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // Eight named swatches, each a well-formed hex.
    expect(ConnectionColor.allCases.count == 8, "palette has 8 colours")
    expect(ConnectionColor.allCases.allSatisfy { ChartPalette.rgb(fromHex: $0.hex) != nil },
           "every swatch hex parses")
    expect(Set(ConnectionColor.allCases.map { $0.hex }).count == 8, "swatch hexes are distinct")
    expect(Set(ConnectionColor.allCases.map { $0.displayName }).count == 8, "swatch names are distinct")

    // The stored value round-trips back to the swatch that produced it — this
    // is what keeps a saved connection selecting the right menu item.
    for swatch in ConnectionColor.allCases {
        expect(ConnectionColor.named(forHex: swatch.hex) == swatch, "\(swatch.displayName) round-trips")
    }
    expect(ConnectionColor.named(forHex: "#ff3b30") == .red, "hex match ignores case")
    expect(ConnectionColor.named(forHex: nil) == nil, "no colour is not a swatch")
    expect(ConnectionColor.named(forHex: "#123456") == nil, "an off-palette hex names no swatch")

    // Any well-formed hex still resolves to a colour, so a record carrying a
    // colour from elsewhere is drawn rather than dropped.
    expect(ConnectionColor.color(forHex: "#123456") != nil, "off-palette hex still resolves")
    expect(ConnectionColor.color(forHex: nil) == nil, "no colour resolves to nothing")
    expect(ConnectionColor.color(forHex: "not a colour") == nil, "malformed hex resolves to nothing")

    // The resolved colour is the hex, exactly — the stored value and the drawn
    // swatch must not disagree.
    if let red = ConnectionColor.color(forHex: "#FF3B30")?.usingColorSpace(.sRGB) {
        expect(Int((red.redComponent * 255).rounded()) == 0xFF, "red component matches hex")
        expect(Int((red.greenComponent * 255).rounded()) == 0x3B, "green component matches hex")
        expect(Int((red.blueComponent * 255).rounded()) == 0x30, "blue component matches hex")
    } else {
        failures += 1
        print("FAIL red resolves in sRGB")
    }

    // `label` is what a tooltip and an accessibility value say.
    expect(ConnectionColor.label(forHex: "#007AFF") == "Blue", "label names a known swatch")
    expect(ConnectionColor.label(forHex: "#123456") == "#123456", "label falls back to the hex")
    expect(ConnectionColor.label(forHex: nil) == nil, "no colour has no label")
    expect(ConnectionColor.label(forHex: "nonsense") == nil, "malformed hex has no label")

    // The band's text colour: dark text on the light swatches, light on the
    // dark ones, so the name stays readable whichever colour is chosen.
    expect(ConnectionColor.foreground(onHex: ConnectionColor.yellow.hex) == .black, "dark text on yellow")
    expect(ConnectionColor.foreground(onHex: ConnectionColor.blue.hex) == .white, "light text on blue")
    expect(ConnectionColor.foreground(onHex: ConnectionColor.purple.hex) == .white, "light text on purple")

    // A swatch image is produced for a colour and withheld for none, so a
    // caller can assign the result straight to a menu item's `image`.
    expect(ConnectionColor.swatchImage(forHex: ConnectionColor.teal.hex)?.size
           == NSSize(width: 10, height: 10), "swatch is 10pt by default")
    expect(ConnectionColor.swatchImage(forHex: nil) == nil, "no colour makes no swatch")

    // The config carries the colour through its own coding, including absent.
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let coloured = ConnectionConfig(id: "1", name: "prod", host: "h", port: 5432,
                                    database: "d", username: "u", color: ConnectionColor.red.hex)
    if let data = try? encoder.encode(coloured),
       let back = try? decoder.decode(ConnectionConfig.self, from: data) {
        expect(back.color == ConnectionColor.red.hex, "colour survives encode/decode")
    } else {
        failures += 1
        print("FAIL colour survives encode/decode")
    }
    if let data = "{\"id\":\"1\",\"name\":\"n\",\"host\":\"h\",\"port\":5432,\"database\":\"d\",\"username\":\"u\"}".data(using: .utf8),
       let back = try? decoder.decode(ConnectionConfig.self, from: data) {
        expect(back.color == nil, "an absent colour key decodes to none")
    } else {
        failures += 1
        print("FAIL an absent colour key decodes to none")
    }

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
