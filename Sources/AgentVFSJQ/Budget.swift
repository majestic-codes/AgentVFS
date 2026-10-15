//
//  Budget.swift
//  AgentVFSJQ
//
//  Created by Yevhenii Kalashnikov on 14.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Darwin
import Foundation
import Synchronization

/// Stops a running program from another thread.
final class JQCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    func cancel() {
        flag.store(true, ordering: .relaxed)
    }

    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// What one run of a program may spend besides evaluation steps: wall-clock time and memory.
///
/// Memory is the growth of the process footprint since the run started, so it counts what jq
/// really holds, garbage it already released aside. Code that builds values notes the bytes they
/// take, an estimate that decides when to measure the footprint, and code about to build a large
/// value reserves its bytes first, so a value that cannot fit is refused before it is built.
///
/// The footprint belongs to the whole process. While other runs are active, growth they cause
/// counts here too, so a run is stopped only once it has itself noted at least half the limit.
/// When the system does not report the footprint, the bytes noted since the run started stand in
/// for it. They count memory already released too, so such a run stops early rather than late.
final class Budget {
    private let timeout: Duration
    private let deadline: ContinuousClock.Instant
    private let maxMemoryGrowth: Int
    /// The footprint when the run started, or `nil` when the system did not report it.
    private let baseline: UInt64?
    private let cancellation: JQCancellation?
    /// Calls to `checkPeriodically` so far.
    private var periodicCalls = 0
    /// Bytes noted since the footprint was last measured.
    private var unmeasuredBytes = 0
    /// Bytes noted since the run started: the run's own share of the growth, by estimate.
    private var notedBytes = 0
    /// Footprint growth at the last measurement.
    private var measuredGrowth = 0
    private static let measureEveryBytes = 16 << 20
    /// Budgets of runs in progress in this process.
    private static let activeRuns = Atomic<Int>(0)

    /// Bytes a `JSONValue` takes inside an array or object.
    static let valueBytes = MemoryLayout<JSONValue>.stride
    /// Bytes an array, string or dictionary storage takes besides its elements.
    static let storageBytes = 32
    /// Bytes one key of an object takes besides the key's text: its slots in the key and value
    /// arrays and in the position table.
    static let memberBytes = 80

    init(_ options: JQ.Options, cancellation: JQCancellation?) {
        timeout = options.timeout
        deadline = ContinuousClock.now + options.timeout
        maxMemoryGrowth = options.maxMemoryGrowth
        baseline = Self.footprint()
        self.cancellation = cancellation
        Self.activeRuns.add(1, ordering: .relaxed)
    }

    deinit {
        Self.activeRuns.subtract(1, ordering: .relaxed)
    }

    /// Throws once the run is cancelled or out of time.
    func check() throws {
        if let failure = failure() { throw failure }
    }

    /// `check` every 4096 calls, for walks over values whose single steps are cheap but whose
    /// count can be exponential in the value's storage.
    func checkPeriodically() throws {
        periodicCalls &+= 1
        if periodicCalls & 4095 == 0 { try check() }
    }

    /// Measures the footprint now.
    func checkMemory() throws {
        if let failure = memoryFailure(adding: 0) { throw failure }
    }

    /// Notes `bytes` newly allocated. Every 16 MB noted, and every megabyte once the estimate
    /// passes the limit, checks time and memory, so large values are measured soon after they are built. A
    /// value of a megabyte or more checks the time too, since building it took a while.
    func note(allocating bytes: Int) throws {
        if bytes >= 1 << 20 { try check() }
        unmeasuredBytes += bytes
        notedBytes += bytes
        let nearLimit = unmeasuredBytes >= 1 << 20 && measuredGrowth + unmeasuredBytes > maxMemoryGrowth
        guard unmeasuredBytes >= Self.measureEveryBytes || nearLimit else { return }
        try check()
        try checkMemory()
    }

    /// Checks that `bytes` more can be allocated before they are, then notes them. Throws when the
    /// growth measured now plus `bytes` passes the limit.
    func reserve(_ bytes: Int) throws {
        try check()
        let pending = unmeasuredBytes + bytes
        if pending >= Self.measureEveryBytes || (pending >= 1 << 20 && measuredGrowth + pending > maxMemoryGrowth) {
            if let failure = memoryFailure(adding: bytes) { throw failure }
        }
        try note(allocating: bytes)
    }

    /// Why the run must stop, or `nil`. For code that cannot throw where it notices.
    func failure(allocating bytes: Int = 0) -> JQAbort? {
        if cancellation?.isCancelled == true { return JQAbort(message: "jq was stopped") }
        if ContinuousClock.now >= deadline {
            let shown = timeout.formatted(.units(allowed: [.seconds, .milliseconds], width: .wide, maximumUnitCount: 1))
            return JQAbort(message: "program ran longer than the time limit of \(shown)")
        }
        unmeasuredBytes += bytes
        notedBytes += bytes
        guard unmeasuredBytes >= Self.measureEveryBytes else { return nil }
        return memoryFailure(adding: 0)
    }

    /// Measures the footprint and returns why the run must stop if it grew past the limit, or
    /// would with `extra` bytes more.
    private func memoryFailure(adding extra: Int) -> JQAbort? {
        unmeasuredBytes = 0
        let overLimit = JQAbort(message: "program used more than the memory limit of \(maxMemoryGrowth >> 20) MB")
        guard let baseline, let current = Self.footprint() else {
            return notedBytes + extra > maxMemoryGrowth ? overLimit : nil
        }
        measuredGrowth = current > baseline ? Int(clamping: current - baseline) : 0
        guard measuredGrowth + extra > maxMemoryGrowth else { return nil }
        let shared = Self.activeRuns.load(ordering: .relaxed) > 1
        if shared && notedBytes + extra < maxMemoryGrowth / 2 { return nil }
        return overLimit
    }

    /// The process's physical footprint in bytes, as the system counts it against memory limits.
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
