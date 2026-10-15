//
//  DeadlineRace.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Synchronization

/// Runs an operation against a deadline without waiting for it once the deadline passes, even
/// when the operation ignores cancellation.
enum DeadlineRace {
    /// The result of `operation`, or `nil` when `deadline` passes first. The operation is then
    /// cancelled and left to end on its own. Throws `CancellationError` as soon as the task is cancelled.
    static func run<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { return nil }
        let gate = RaceGate<Value>()
        let work = Task {
            do {
                let value = try await operation()
                gate.resolve(.success(value))
            } catch {
                gate.resolve(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                // The work finished first and cancelled the timer.
                return
            }
            gate.resolve(.success(nil))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation with whichever result comes first.
private final class RaceGate<Value: Sendable>: Sendable {
    private enum State {
        case waiting
        case installed(CheckedContinuation<Value?, any Error>)
        /// A result that came before the continuation was installed.
        case early(Result<Value?, any Error>)
        case finished
    }

    private let state = Mutex(State.waiting)

    func install(_ continuation: CheckedContinuation<Value?, any Error>) {
        let early = state.withLock { state -> Result<Value?, any Error>? in
            switch state {
            case .waiting:
                state = .installed(continuation)
                return nil
            case let .early(result):
                state = .finished
                return result
            case .installed, .finished:
                preconditionFailure("a race gate takes one continuation")
            }
        }
        if let early { continuation.resume(with: early) }
    }

    func resolve(_ result: Result<Value?, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value?, any Error>? in
            switch state {
            case .waiting:
                state = .early(result)
                return nil
            case let .installed(continuation):
                state = .finished
                return continuation
            case .early, .finished:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
