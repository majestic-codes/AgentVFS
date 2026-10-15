//
//  Gate.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Synchronization

/// Holds a task at `pass()` until the test calls `open()`, so the test can act while the task waits.
final class Gate: Sendable {
    private struct State {
        var isEntered = false
        var isOpen = false
        var waiting: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Whether a task reached `pass()`.
    var isEntered: Bool { state.withLock(\.isEntered) }

    /// Waits until the gate is open.
    func pass() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                state.isEntered = true
                guard !state.isOpen else { return true }
                state.waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets the waiting task, and every later one, through.
    func open() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isOpen = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }

    /// Returns once a task waits at the gate.
    func waitUntilEntered() async {
        while !isEntered { await Task.yield() }
    }
}
