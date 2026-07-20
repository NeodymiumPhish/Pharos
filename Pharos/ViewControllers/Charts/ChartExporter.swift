import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Chart + provenance caption footer, laid out for export. Forces light
/// appearance and an opaque white background so PNG/PDF output is
/// predictable regardless of the app's current appearance.
struct ChartExportView: View {
    let data: ChartData
    let config: ChartConfig
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChartCanvas(data: data, config: config, ganttScrollable: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// Renders a chart export view to PNG/PDF via `ImageRenderer`. Not unit
/// tested — `ImageRenderer` doesn't run headless — this is build-gated and
/// verified manually (see the phase-3 plan's Task 1 verify step). The pure,
/// tested half (the provenance caption text) lives in `ChartExportCaption`.
enum ChartExporter {

    /// Renders `view` to a retina PNG with the provenance embedded as
    /// standard PNG tEXt chunks via ImageIO's PNG property dictionary:
    /// `kCGImagePropertyPNGComment` -> "Comment", `kCGImagePropertyPNGSoftware`
    /// -> "Software", `kCGImagePropertyPNGCreationTime` -> "Creation Time",
    /// and (when `sql` is non-nil) `kCGImagePropertyPNGDescription` ->
    /// "Description". These are documented ImageIO PNG metadata keys on the
    /// macOS 15 SDK (`CGImageProperties.h`) and round-trip as real tEXt
    /// chunks readable by `sips`/`exiftool`/any PNG metadata reader.
    @MainActor
    static func png(of view: some View, size: CGSize, scale: CGFloat = 2,
                     caption: String, sql: String?, timestamp: String) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }

        var pngProps: [CFString: Any] = [
            kCGImagePropertyPNGComment: caption,
            kCGImagePropertyPNGSoftware: "Pharos",
            kCGImagePropertyPNGCreationTime: timestamp,
        ]
        if let sql { pngProps[kCGImagePropertyPNGDescription] = sql }
        let properties: [CFString: Any] = [kCGImagePropertyPNGDictionary: pngProps]

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Renders `view` to a single-page PDF with the provenance embedded in
    /// the standard PDF document-info dictionary (Quartz's `CGContext`
    /// auxiliary-info, keyed by the documented `kCGPDFContext*` constants):
    /// `kCGPDFContextCreator` = "Pharos", `kCGPDFContextSubject` = the full
    /// caption, and (when `sql` is non-nil) `kCGPDFContextKeywords` = `[sql]`.
    /// These show up as the PDF's Creator/Subject/Keywords properties in
    /// Preview's Inspector or any PDF metadata reader.
    @MainActor
    static func pdf(of view: some View, size: CGSize, caption: String, sql: String?, timestamp: String) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.isOpaque = true

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }

        var auxInfo: [CFString: Any] = [
            kCGPDFContextCreator: "Pharos",
            kCGPDFContextSubject: caption,
        ]
        if let sql { auxInfo[kCGPDFContextKeywords] = [sql] as CFArray }

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
