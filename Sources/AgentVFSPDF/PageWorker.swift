//
//  PageWorker.swift
//  AgentVFSPDF
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Dispatch
import Synchronization

/// Runs blocking PDFKit and Vision work on threads of its own, so a slow page holds none of the
/// threads Swift concurrency shares.
enum PageWorker {
    private static let queue = DispatchQueue(
        label: "AgentVFSPDF.pages",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    /// The result of `work`, or `nil` when `deadline` passes first. Work that passes the deadline
    /// is abandoned: it runs to its end in the background and its result is dropped. Throws
    /// `CancellationError` as soon as the task is cancelled.
    static func run<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value? {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let gate = Gate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                queue.async {
                    gate.resolve(Result { try work() }.map(Optional.some))
                }
                // The timer runs on a global queue, so busy page workers cannot hold it back.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + dispatchInterval(remaining)) {
                    gate.resolve(.success(nil))
                }
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let milliseconds = (duration / .milliseconds(1)).rounded(.up)
        return .milliseconds(Int(min(milliseconds, Double(Int32.max))))
    }
}

/// Resumes a continuation with whichever result comes first: the work, the deadline or cancellation.
private final class Gate<Value: Sendable>: Sendable {
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
                preconditionFailure("a gate takes one continuation")
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
