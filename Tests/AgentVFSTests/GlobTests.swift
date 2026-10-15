//
//  GlobTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Testing
@testable import AgentVFS

@Suite("Glob")
struct GlobTests {
    @Test("star, question mark and classes")
    func basics() throws {
        let swift = try Glob("*.swift")
        #expect(swift.matches("SyncManager.swift"))
        #expect(swift.matches("SyncManager.kt") == false)
        #expect(swift.matches("dir/SyncManager.swift") == false)
        #expect(try Glob("Sync?anager.swift").matches("SyncManager.swift"))
        #expect(try Glob("[A-C]*.kt").matches("Alpha.kt"))
        #expect(try Glob("[A-C]*.kt").matches("Delta.kt") == false)
        #expect(try Glob("[!A-C]*.kt").matches("Delta.kt"))
    }

    @Test("brace alternatives")
    func braces() throws {
        let glob = try Glob("*.{swift,kt}")
        #expect(glob.matches("a.swift"))
        #expect(glob.matches("a.kt"))
        #expect(glob.matches("a.java") == false)
    }

    @Test("double star crosses directories")
    func doubleStar() throws {
        let glob = try Glob("Sources/**/*.swift")
        #expect(glob.matches("Sources/Sync/SyncManager.swift"))
        #expect(glob.matches("Sources/A/B/C.swift"))
        #expect(glob.matches("Sources/C.swift"))
        #expect(glob.matches("Tests/C.swift") == false)
    }

    @Test("case insensitive matching")
    func caseInsensitive() throws {
        #expect(try Glob("*.SWIFT", caseInsensitive: true).matches("a.swift"))
        #expect(try Glob("*.SWIFT").matches("a.swift") == false)
    }

    @Test("regex metacharacters in the glob are literal")
    func literalMetacharacters() throws {
        let glob = try Glob("a+b(1).txt")
        #expect(glob.matches("a+b(1).txt"))
        #expect(glob.matches("aab(1)xtxt") == false)
    }

    @Test("unterminated class is an error")
    func invalid() {
        #expect(throws: VFSError.self) { try Glob("[abc") }
        #expect(throws: VFSError.self) { try Glob("{a,b") }
    }
}
