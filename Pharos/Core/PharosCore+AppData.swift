import Foundation
import CPharosCore

// MARK: - App data export and import
//
// Swift side of pharos-core/src/ffi/app_backup.rs. All three calls are async:
// the key derivation takes a noticeable fraction of a second, and a file with
// Sessions' saved results in it can be large.

extension PharosCore {

    /// Write the chosen categories to `options.path`.
    static func exportAppData(_ options: ExportAppDataOptions) async throws -> ExportAppDataResult {
        let json = String(decoding: try JSONEncoder.pharos.encode(options), as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            json.withCString { pharos_export_app_data($0, callback, context) }
        }
    }

    /// What the file at `path` holds. An encrypted file read without
    /// `passphrase` answers `locked`; a wrong passphrase throws.
    static func inspectAppData(path: String, passphrase: String?) async throws -> AppDataSummary {
        struct Request: Encodable {
            let path: String
            let passphrase: String?
        }
        let json = String(decoding: try JSONEncoder.pharos.encode(Request(path: path, passphrase: passphrase)),
                          as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            json.withCString { pharos_inspect_app_data($0, callback, context) }
        }
    }

    /// Read the chosen categories from a file into this Mac's store. Nothing
    /// already in the store is deleted.
    static func importAppData(_ options: ImportAppDataOptions) async throws -> ImportAppDataResult {
        let json = String(decoding: try JSONEncoder.pharos.encode(options), as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            json.withCString { pharos_import_app_data($0, callback, context) }
        }
    }
}
