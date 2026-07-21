import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The chart laid out for export. Forces light appearance and an opaque white
/// background so PNG/PDF output is predictable regardless of the app's current
/// appearance. No provenance footer — exports are the chart alone.
struct ChartExportView: View {
    let data: ChartData
    let config: ChartConfig
    let globalPalette: [String]

    var body: some View {
        ChartCanvas(data: data, config: config, ganttScrollable: false, globalPalette: globalPalette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(Color.white)
            .environment(\.colorScheme, .light)
    }
}

/// Renders a chart export view to PNG/PDF via `ImageRenderer`. Not unit tested —
/// `ImageRenderer` doesn't run headless — this is build-gated and verified
/// manually. No query/connection provenance is embedded: only generic file
/// metadata (Software/Creator = "Pharos", PNG creation time).
enum ChartExporter {

    /// Renders `view` to a retina PNG. The only embedded metadata is the generic
    /// `kCGImagePropertyPNGSoftware` ("Pharos") and `kCGImagePropertyPNGCreationTime`
    /// — no caption, connection name, or SQL.
    @MainActor
    static func png(of view: some View, size: CGSize, scale: CGFloat = 2, timestamp: String) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }

        let pngProps: [CFString: Any] = [
            kCGImagePropertyPNGSoftware: "Pharos",
            kCGImagePropertyPNGCreationTime: timestamp,
        ]
        let properties: [CFString: Any] = [kCGImagePropertyPNGDictionary: pngProps]

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Renders `view` to a single-page PDF. The only embedded metadata is the
    /// generic `kCGPDFContextCreator` ("Pharos") — no caption or SQL.
    @MainActor
    static func pdf(of view: some View, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.isOpaque = true

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }

        let auxInfo: [CFString: Any] = [kCGPDFContextCreator: "Pharos"]

        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, auxInfo as CFDictionary) else { return nil }

        renderer.render { _, renderInContext in
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
