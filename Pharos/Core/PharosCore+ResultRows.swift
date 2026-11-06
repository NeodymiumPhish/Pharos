import Foundation
import CPharosCore

// The result-row half of the async bridge (`PharosCore.swift`): calls whose
// rows come back as a PRB1 block through `BlockCallback`. Kept out of
// `PharosCore.swift` so that file names no model type: harnesses compile it
// on its own (tasks/lessons.md, 2026-09-21).

/// A result whose rows can arrive as a PRB1 block beside its JSON
/// (`BlockCallback`): the JSON then carries `"rows":[]`.
protocol CarriesResultRows {
    mutating func adoptRows(_ rows: ResultTable)
}

extension QueryResult: CarriesResultRows {
    mutating func adoptRows(_ rows: ResultTable) { self.rows = rows }
}

extension SessionResult: CarriesResultRows where Payload == QueryResult {
    mutating func adoptRows(_ rows: ResultTable) { payload.rows = rows }
}

/// As `continuationHandler`, putting the block's rows on the decoded result.
private func rowsContinuationHandler<T: Decodable & CarriesResultRows>(
    _ continuation: CheckedContinuation<T, Error>, slot: BlockSlot
) -> (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void {
    return { resultJson, errorMsg in
        var answer: Result<T, Error> = decodeAnswer(resultJson, errorMsg)
        if case .success(var value) = answer, let block = slot.block {
            do {
                value.adoptRows(try ResultTable(block: block))
                answer = .success(value)
            } catch {
                answer = .failure(PharosCoreError.rustError("The result's rows could not be read: \(error)"))
            }
        }
        slot.block = nil
        continuation.resume(with: answer)
    }
}

/// As `withAsyncCallback`, for a call that hands its rows over as a PRB1
/// block (`BlockCallback`) beside the rest of its result as JSON.
func withResultCallback<T: Decodable & CarriesResultRows>(
    _ invoke: @escaping (AsyncCallback, BlockCallback, UnsafeMutableRawPointer) -> Void
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let slot = BlockSlot()
        let box = RowsCallbackBox(slot: slot, handler: rowsContinuationHandler(continuation, slot: slot))
        let context = Unmanaged.passRetained(box).toOpaque()
        invoke(asyncCompletionTrampoline, asyncBlockTrampoline, context)
    }
}

/// As `withResultCallback`, for a call that also reports progress.
func withResultCallback<T: Decodable & CarriesResultRows>(
    onProgress: @escaping @Sendable (Int) -> Void,
    _ invoke: @escaping (AsyncCallback, ProgressCallback, BlockCallback, UnsafeMutableRawPointer) -> Void
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let slot = BlockSlot()
        let box = RowsCallbackBox(slot: slot, handler: rowsContinuationHandler(continuation, slot: slot),
                                  progress: onProgress)
        let context = Unmanaged.passRetained(box).toOpaque()
        invoke(asyncCompletionTrampoline, asyncProgressTrampoline, asyncBlockTrampoline, context)
    }
}

