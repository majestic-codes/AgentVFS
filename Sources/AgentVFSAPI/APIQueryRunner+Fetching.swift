//
//  APIQueryRunner+Fetching.swift
//  AgentVFSAPI
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import AgentVFS
import AgentVFSJQ

extension APIQueryRunner {
    struct Fetched {
        var records: [JSONValue] = []
        var pages = 0
        var total: Int?
        var moreAvailable = false
        /// Why fetching stopped before the last page, which makes the records partial.
        var failure: String?
    }

    /// Follows the pages until `wanted` records, the last page, a limit or an error. Throws
    /// `CancellationError` when the task is cancelled.
    func fetch(parameters: [String: String], wanted: Int, deadline: ContinuousClock.Instant) async throws -> Fetched {
        var fetched = Fetched()
        var cursor: String?
        while true {
            if fetched.pages >= maxPages {
                fetched.moreAvailable = true
                fetched.failure = "page limit of \(maxPages) reached"
                break
            }
            let remaining = wanted - fetched.records.count
            let query = APIQuery(parameters: parameters, cursor: cursor, page: fetched.pages + 1, remaining: remaining)
            let page: APIPage
            do {
                let fetchPage = fetchPage
                guard let answered = try await DeadlineRace.run(until: deadline, { try await fetchPage(query) }) else {
                    fetched.moreAvailable = true
                    fetched.failure = "time limit reached after \(fetched.pages) pages"
                    break
                }
                page = answered
            } catch is CancellationError {
                throw CancellationError()
            } catch VFSError.cancelled {
                throw CancellationError()
            } catch {
                fetched.failure = describeError(error)
                break
            }
            fetched.pages += 1
            fetched.total = page.total ?? fetched.total
            let taken = min(page.records.count, remaining)
            fetched.records += page.records.prefix(taken)
            if fetched.records.count >= wanted {
                fetched.moreAvailable = page.nextCursor != nil || page.records.count > taken
                break
            }
            guard let next = page.nextCursor, !page.records.isEmpty else { break }
            if next == cursor {
                fetched.failure = "the API returned the same cursor twice"
                break
            }
            cursor = next
        }
        return fetched
    }
}
