// Copyright (c) 2026 chai-in
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Bridges a one-shot callback API, including synchronous completion and cancellation
/// before the underlying request has returned its cancellation handle.
///
/// Call `value()` once per instance. The first completion or cancellation wins.
/// If the request starts, its cancellation closure runs once when the operation
/// finishes, including after success or failure. It must be safe to call from
/// any thread.
public final class PhotoRequestOperation<Value: Sendable>: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<Value, Error>) -> Void
    public typealias Cancellation = @Sendable () -> Void
    public typealias Start = @Sendable (@escaping Completion) -> Cancellation

    private enum State {
        case idle
        case running(CheckedContinuation<Value, Error>)
        case finished
    }

    private let lock = NSLock()
    private let start: Start
    private var state = State.idle
    private var cancellation: Cancellation?

    public init(start: @escaping Start) {
        self.start = start
    }

    public func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let canStart = lock.withLock {
                    guard case .idle = state else { return false }
                    state = .running(continuation)
                    return true
                }
                guard canStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let cancel = start { [weak self] result in self?.finish(result) }
                let alreadyFinished = lock.withLock {
                    if case .finished = state { return true }
                    cancellation = cancel
                    return false
                }
                if alreadyFinished { cancel() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        let pending: (CheckedContinuation<Value, Error>?, Cancellation?) = lock.withLock {
            let continuation: CheckedContinuation<Value, Error>?
            switch state {
            case .finished: return (nil, nil)
            case .idle: continuation = nil
            case let .running(value): continuation = value
            }
            state = .finished
            let cancel = cancellation
            cancellation = nil
            return (continuation, cancel)
        }
        // PhotoKit may synchronously invoke its callback when cancelled. Never call
        // external code or resume a continuation while holding our state lock.
        pending.1?()
        pending.0?.resume(with: result)
    }
}
