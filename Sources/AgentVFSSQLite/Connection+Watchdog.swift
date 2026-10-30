//
//  Connection+Watchdog.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 30.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Synchronization

extension Connection {
    /// Stops a running statement at its deadline, or when the command is cancelled from another thread.
    final class Watchdog: Sendable {
        let deadline: ContinuousClock.Instant
        private let expiredFlag = Atomic(false)
        private let cancelledFlag = Atomic(false)

        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

        var expired: Bool { expiredFlag.load(ordering: .relaxed) }
        var cancelled: Bool { cancelledFlag.load(ordering: .relaxed) }

        func cancel() { cancelledFlag.store(true, ordering: .relaxed) }

        /// Whether the statement must stop now.
        func shouldStop() -> Bool {
            if cancelled { return true }
            guard ContinuousClock.now > deadline else { return false }
            expiredFlag.store(true, ordering: .relaxed)
            return true
        }
    }
}
