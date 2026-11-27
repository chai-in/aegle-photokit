// Copyright (c) 2026 chai-in
// SPDX-License-Identifier: AGPL-3.0-only

import Dispatch
import Foundation
import XCTest
import AeglePhotoKit

@MainActor
final class PhotoRequestOperationTests: XCTestCase {
    func testSynchronousCompletionAndRepeatedCallbacksResumeOnlyOnce() async throws {
        let harness = PhotoRequestHarness<Int>()
        let operation = PhotoRequestOperation<Int> { completion in
            harness.start(completion)
            completion(.success(42))
            completion(.success(99))
            return { harness.cancel() }
        }
        let value = try await operation.value()
        XCTAssertEqual(value, 42)
        XCTAssertEqual(harness.cancellationCount, 1)
    }

    func testAsynchronousFailureIsForwardedAndCleansUp() async {
        let harness = PhotoRequestHarness<Int>()
        let task = Task {
            try await PhotoRequestOperation<Int> { completion in
                harness.start(completion)
                return { harness.cancel() }
            }.value()
        }

        await waitUntil { harness.hasStarted }
        harness.complete(.failure(TestError.requestFailed))

        do {
            _ = try await task.value
            XCTFail("Expected the callback error")
        } catch {
            XCTAssertEqual(error as? TestError, .requestFailed)
        }
        XCTAssertEqual(harness.cancellationCount, 1)
    }

    func testCancellationBeforeStartDoesNotSubmitARequest() async {
        let gate = AsyncTestGate()
        let harness = PhotoRequestHarness<Int>()
        let task = Task {
            await gate.wait()
            return try await PhotoRequestOperation<Int> { completion in
                harness.start(completion)
                return { harness.cancel() }
            }.value()
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(harness.hasStarted)
    }

    func testCancellationHandlesReentrantAndLateCallbacks() async {
        let harness = PhotoRequestHarness<Int>()
        let task = Task {
            try await PhotoRequestOperation<Int> { completion in
                harness.start(completion)
                return {
                    harness.cancel()
                    completion(.failure(CancellationError()))
                }
            }.value()
        }
        await waitUntil { harness.hasStarted }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        harness.complete(.success(123))
        XCTAssertEqual(harness.cancellationCount, 1)
    }

    func testCancellationBeforeHandleIsReturnedStillInvokesHandle() async {
        let harness = PhotoRequestHarness<Int>()
        let releaseStart = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await PhotoRequestOperation<Int> { completion in
                harness.start(completion)
                guard releaseStart.wait(timeout: .now() + 5) == .success else {
                    completion(.failure(TestError.requestTimedOut))
                    return {}
                }
                completion(.success(42))
                return { harness.cancel() }
            }.value()
        }

        await waitUntil { harness.hasStarted }
        task.cancel()
        releaseStart.signal()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.cancellationCount, 1)
    }

    func testCompletionRacingCancellationHasOneTerminalResult() async throws {
        for _ in 0..<24 {
            let harness = PhotoRequestHarness<Int>()
            let task = Task {
                try await PhotoRequestOperation<Int> { completion in
                    harness.start(completion)
                    return { harness.cancel() }
                }.value()
            }
            await waitUntil { harness.hasStarted }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { harness.complete(.success(7)) }
                group.addTask { task.cancel() }
            }
            do {
                let value = try await task.value
                XCTAssertEqual(value, 7)
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(harness.cancellationCount, 1)
        }
    }
}

private enum TestError: Error, Equatable {
    case requestFailed
    case requestTimedOut
}

/// Test callbacks may run on any queue, just like the PhotoKit callbacks they represent.
private final class PhotoRequestHarness<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: PhotoRequestOperation<Value>.Completion?
    private var cancellations = 0

    var hasStarted: Bool { lock.withLock { completion != nil } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func start(_ completion: @escaping PhotoRequestOperation<Value>.Completion) {
        lock.withLock { self.completion = completion }
    }

    func cancel() { lock.withLock { cancellations += 1 } }

    func complete(_ result: Result<Value, Error>) {
        let callback = lock.withLock { completion }
        callback?(result)
    }
}

@MainActor
private func waitUntil(
    timeoutIterations: Int = 200,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<timeoutIterations {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for state", file: file, line: line)
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}
