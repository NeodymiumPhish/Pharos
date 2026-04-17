import AppKit
import Foundation

enum CrashLogger {

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    static func install() {
        NSSetUncaughtExceptionHandler(pharosUncaughtExceptionHandler)
    }

    private static func writeToFile(name: String, reason: String, stack: String) {
        let fm = FileManager.default
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return
        }
        let logsDir = libraryURL.appendingPathComponent("Logs/Pharos", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let timestamp = timestampFormatter.string(from: Date())
        let fileURL = logsDir.appendingPathComponent("pharos-crash-\(timestamp).log")

        let body = """
        Pharos uncaught exception
        Timestamp (UTC): \(timestamp)
        Name:   \(name)
        Reason: \(reason)

        Stack:
        \(stack)

        """

        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    fileprivate static func handle(_ exception: NSException) {
        let name = exception.name.rawValue
        let reason = exception.reason ?? "<no reason>"
        let stack = exception.callStackSymbols.joined(separator: "\n")

        NSLog("[Pharos] UNCAUGHT EXCEPTION: %@", name)
        NSLog("[Pharos] REASON: %@", reason)
        NSLog("[Pharos] STACK:\n%@", stack)

        writeToFile(name: name, reason: reason, stack: stack)
    }
}

// Top-level function — no captured context, so it converts to a C function pointer.
private func pharosUncaughtExceptionHandler(_ exception: NSException) {
    CrashLogger.handle(exception)
}
