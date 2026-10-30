//
//  LRUCache.swift
//  AgentVFS
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

/// A cost-bounded least-recently-used cache. Not thread-safe. Owned by one actor.
package struct LRUCache<Key: Hashable, Value> {
    private struct Slot {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    package let capacity: Int
    private var slots: [Key: Slot] = [:]
    private var clock: UInt64 = 0
    package private(set) var totalCost = 0

    package init(capacity: Int) {
        self.capacity = capacity
    }

    package mutating func value(for key: Key) -> Value? {
        guard var slot = slots[key] else { return nil }
        clock += 1
        slot.lastUse = clock
        slots[key] = slot
        return slot.value
    }

    package mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in slots.keys where shouldRemove(key) {
            if let slot = slots.removeValue(forKey: key) {
                totalCost -= slot.cost
            }
        }
    }

    package mutating func removeAll() {
        slots.removeAll()
        totalCost = 0
    }

    /// Stores `value`, evicting the least recently used entries until it fits.
    /// Values costing more than the whole capacity are not stored.
    package mutating func insert(_ value: Value, cost: Int, for key: Key) {
        if let existing = slots.removeValue(forKey: key) {
            totalCost -= existing.cost
        }
        guard cost <= capacity else { return }
        while totalCost + cost > capacity, let victim = slots.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            slots.removeValue(forKey: victim.key)
            totalCost -= victim.value.cost
        }
        clock += 1
        slots[key] = Slot(value: value, cost: cost, lastUse: clock)
        totalCost += cost
    }
}
