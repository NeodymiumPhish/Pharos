import Foundation
import CPharosCore

// MARK: - PharosCore

/// Swift bridge to the Rust pharos-core static library.
/// Wraps C FFI functions with type-safe Swift interfaces.
///
/// Domain methods are organized in extension files:
///   PharosCore+Connection.swift     — connect, disconnect, test, load/save/delete
///   PharosCore+Query.swift          — execute, fetch, cancel, validate, format
///   PharosCore+Schema.swift         — schemas, tables, columns, functions, analyze
///   PharosCore+TableMetadata.swift  — indexes, constraints
///   PharosCore+TableOps.swift       — clone, export, import
///   PharosCore+QueryHistory.swift   — load, delete, get result
///   PharosCore+SavedQueries.swift   — CRUD for saved queries
///   PharosCore+Settings.swift       — load/save settings
enum PharosCore { }

// MARK: - Async Callback Bridge

/// Type-erased box to carry a callback handler through a void* context pointer.
/// The handler closure captures the generic type and continuation,
/// keeping the C function pointer free of generic parameters.
class CallbackBox {
    let handler: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    init(handler: @escaping (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void) {
        self.handler = handler
    }
}

/// Bridge between C callback pattern and Swift async/await.
/// Wraps a C function that takes (callback, context) into an async throwing call.
func withAsyncCallback<T: Decodable>(
    _ invoke: @escaping (AsyncCallback, UnsafeMutableRawPointer) -> Void
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let box = CallbackBox { resultJson, errorMsg in
            if let errorMsg {
                let error = String(cString: errorMsg)
                continuation.resume(throwing: PharosCoreError.rustError(error))
            } else if let resultJson {
                let json = String(cString: resultJson)
                do {
                    let decoded = try JSONDecoder.pharos.decode(T.self, from: Data(json.utf8))
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: PharosCoreError.decodingError(json, error))
                }
            } else {
                continuation.resume(throwing: PharosCoreError.nullResult)
            }
        }
        let context = Unmanaged.passRetained(box).toOpaque()

        let callback: AsyncCallback = { ctx, resultJson, errorMsg in
            guard let ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeRetainedValue()
            box.handler(resultJson, errorMsg)
        }

        invoke(callback, context)
    }
}

/// Dummy Decodable type for void-returning async operations.
struct EmptyResult: Decodable {
    init(from decoder: Decoder) throws {
        // Accept "null" or any value
    }
}

// MARK: - Helpers

/// Call a closure with an optional C string (NULL if nil).
func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let string {
        return string.withCString { body($0) }
    } else {
        return body(nil)
    }
}

// MARK: - JSON Coding

extension JSONDecoder {
    /// Decoder for Rust JSON. No key strategy — models use explicit CodingKeys where needed.
    static let pharos = JSONDecoder()
}

extension JSONEncoder {
    /// Encoder for Rust JSON. No key strategy — models use explicit CodingKeys where needed.
    static let pharos = JSONEncoder()
}

// MARK: - Errors

enum PharosCoreError: LocalizedError {
    case rustError(String)
    case decodingError(String, Error)
    case nullResult

    var errorDescription: String? {
        switch self {
        case .rustError(let msg): return msg
        case .decodingError(let json, let error): return "Failed to decode: \(error). JSON: \(json.prefix(200))"
        case .nullResult: return "Unexpected null result from Rust"
        }
    }
}
