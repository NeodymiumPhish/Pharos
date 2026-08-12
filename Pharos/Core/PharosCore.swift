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
                // Decode directly from the C buffer instead of String(cString:)
                // + Data(json.utf8), which used to make two full-JSON copies
                // per FFI call. The pointer is owned by Rust and freed on
                // callback return, so the no-copy Data is only safe to use
                // synchronously inside this closure — JSONDecoder reads it
                // before we return.
                let length = strlen(resultJson)
                let bytes = UnsafeRawPointer(resultJson)
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
                                count: length,
                                deallocator: .none)
                do {
                    let decoded = try JSONDecoder.pharos.decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    // Only materialize the full string on the error path; the
                    // happy path skips the allocation entirely.
                    let json = String(cString: resultJson)
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
    /// Returns a fresh instance each call since JSONDecoder is not thread-safe.
    static var pharos: JSONDecoder { JSONDecoder() }
}

extension JSONEncoder {
    /// Encoder for Rust JSON. No key strategy — models use explicit CodingKeys where needed.
    /// Returns a fresh instance each call since JSONEncoder is not thread-safe.
    static var pharos: JSONEncoder { JSONEncoder() }
}

// MARK: - Sync FFI Helpers

extension PharosCore {

    /// Call a sync FFI function that returns a JSON C-string, decode the result.
    /// Handles null checks, freeing, the core's error object, and decode failures.
    static func callSync<T: Decodable>(_ ffi: () -> UnsafeMutablePointer<CChar>?) throws -> T {
        guard let ptr = ffi() else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        return try decodeNoCopy(ptr)
    }

    /// Call a sync FFI function with a JSON-encoded input, decode the result.
    static func callSync<T: Decodable, A: Encodable>(
        input: A,
        _ ffi: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(input), as: UTF8.self)
        guard let ptr = jsonStr.withCString({ ffi($0) }) else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        return try decodeNoCopy(ptr)
    }

    /// Decode a JSON C-string without an extra full-string allocation.
    /// `Data(bytesNoCopy:)` is safe here because the FFI pointer outlives the
    /// synchronous decode and is freed by the caller's `defer`.
    private static func decodeNoCopy<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>) throws -> T {
        // Read the failure side of the channel first, or a real core failure would
        // be reported as a decode complaint that quotes `{"error": ...}` instead
        // of naming the locked database. The byte test comes first so that a
        // successful load — which may carry a large result set — never pays the
        // full-string allocation this function exists to avoid.
        if RustScalarError.beginsWithErrorKey(ptr),
           let message = RustScalarError.message(in: String(cString: ptr)) {
            throw PharosCoreError.rustError(message)
        }
        let length = strlen(ptr)
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(ptr),
                        count: length,
                        deallocator: .none)
        do {
            return try JSONDecoder.pharos.decode(T.self, from: data)
        } catch {
            // Allocate the descriptive string only on the error path.
            throw PharosCoreError.decodingError(String(cString: ptr), error)
        }
    }

    // MARK: - Single-Channel Returns
    //
    // The three helpers below serve the FFI functions that do NOT use the
    // NULL-on-success convention of `callSyncVoid`. They return ONE C-string for
    // both outcomes: the result, or the object `{"error": "..."}`. `callSync`
    // above is on the same convention and checks the same way, through
    // `RustScalarError`; these three exist for the return shapes it does not
    // cover — a scalar, and a plain C-string argument.
    //
    // The async FFI needs none of this. `callback_err` in
    // pharos-core/src/ffi/mod.rs delivers a failure through its own argument, so
    // `withAsyncCallback` reads a separate error channel.

    /// Read a single-channel return: free the C-string, and throw when it holds the
    /// core's error object instead of a result.
    ///
    /// This is the ONE place that reads the failure side of the channel. NULL gives
    /// nil, because each wrapper decides for itself what NULL means — "no such
    /// workspace" for one, an unexpected empty return for another. Every wrapper
    /// on this convention starts here, so the check cannot be forgotten at one
    /// call site.
    static func checkedText(
        _ ffi: () -> UnsafeMutablePointer<CChar>?
    ) throws -> String? {
        guard let ptr = ffi() else { return nil }
        defer { pharos_free_string(ptr) }
        let text = String(cString: ptr)
        if let message = RustScalarError.message(in: text) {
            throw PharosCoreError.rustError(message)
        }
        return text
    }

    /// Call a sync FFI function whose return is a SCALAR, not JSON.
    ///
    /// Success gives `true`, `false` or a decimal. Testing the success text alone
    /// (`== "true"`) silently turns a failure into a negative answer — a locked
    /// database then reads as "nothing was deleted".
    static func scalarResult(
        _ ffi: () -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        guard let text = try checkedText(ffi) else { throw PharosCoreError.nullResult }
        return text
    }

    /// Scalar return, JSON-encoded input. Same contract as `scalarResult(_:)`.
    static func scalarResult<A: Encodable>(
        input: A,
        _ ffi: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(input), as: UTF8.self)
        return try scalarResult { jsonStr.withCString { ffi($0) } }
    }

    /// Call a sync FFI function that takes a plain C-string and returns JSON, and
    /// decode the result.
    ///
    /// `callSync` covers "nothing in" and "JSON in"; this covers the third shape.
    /// The error object is checked before the decode so that a real failure reports
    /// the core's own message instead of a decoding complaint.
    static func jsonResult<T: Decodable>(
        _ ffi: () -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard let json = try checkedText(ffi) else { throw PharosCoreError.nullResult }
        do {
            return try JSONDecoder.pharos.decode(T.self, from: Data(json.utf8))
        } catch {
            throw PharosCoreError.decodingError(json, error)
        }
    }

    /// Call a sync FFI function that returns NULL on success or error string on failure.
    static func callSyncVoid<A: Encodable>(
        input: A,
        _ ffi: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(input), as: UTF8.self)
        let error = jsonStr.withCString { ffi($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }

    /// Call a sync FFI function with a string arg that returns NULL on success or error string.
    static func callSyncVoid(
        id: String,
        _ ffi: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws {
        let error = id.withCString { ffi($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }
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
