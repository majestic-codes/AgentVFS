//
//  VFSPathTests.swift
//  AgentVFSTests
//
//  Created by Yevhenii Kalashnikov on 13.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Testing
@testable import AgentVFS

@Suite("VFSPath")
struct VFSPathTests {
    private let root = VFSPath.root

    @Test("absolute paths normalize")
    func absolutePaths() throws {
        let path = try VFSPath(normalizing: "/workspace/ios//Sources/./App.swift", relativeTo: root)
        #expect(path.components == ["ios", "Sources", "App.swift"])
        #expect(path.description == "/workspace/ios/Sources/App.swift")
    }

    @Test("workspace root has no components")
    func workspaceRoot() throws {
        let path = try VFSPath(normalizing: "/workspace/", relativeTo: root)
        #expect(path.isRoot)
        #expect(path.description == "/workspace")
    }

    @Test("relative paths resolve against cwd")
    func relativePaths() throws {
        let cwd = try VFSPath(normalizing: "/workspace/ios/Sources", relativeTo: root)
        let file = try VFSPath(normalizing: "App.swift", relativeTo: cwd)
        #expect(file.description == "/workspace/ios/Sources/App.swift")
        #expect(try VFSPath(normalizing: "..", relativeTo: cwd).description == "/workspace/ios")
        #expect(try VFSPath(normalizing: "../../android/x", relativeTo: cwd).description == "/workspace/android/x")
        #expect(try VFSPath(normalizing: ".", relativeTo: cwd) == cwd)
        #expect(try VFSPath(normalizing: "", relativeTo: cwd) == cwd)
    }

    @Test("parent traversal above workspace is rejected")
    func traversalRejected() throws {
        let cwd = try VFSPath(normalizing: "/workspace/ios", relativeTo: root)
        #expect(throws: VFSError.outsideWorkspace("../../etc")) {
            try VFSPath(normalizing: "../../etc", relativeTo: cwd)
        }
        #expect(throws: VFSError.outsideWorkspace("/workspace/../etc/passwd")) {
            try VFSPath(normalizing: "/workspace/../etc/passwd", relativeTo: root)
        }
        #expect(throws: VFSError.outsideWorkspace("/workspace/ios/../../..")) {
            try VFSPath(normalizing: "/workspace/ios/../../..", relativeTo: root)
        }
    }

    static let outsidePaths = ["/etc/passwd", "/", "/workspaces/ios", "/Users/me"]

    @Test("absolute paths outside workspace are rejected", arguments: outsidePaths)
    func outsideRejected(raw: String) {
        #expect(throws: VFSError.outsideWorkspace(raw)) {
            try VFSPath(normalizing: raw, relativeTo: VFSPath.root)
        }
    }

    @Test("a tilde is an ordinary name, never a home directory")
    func tildeIsLiteral() throws {
        let path = try VFSPath(normalizing: "~/secrets", relativeTo: VFSPath.root)
        #expect(path.components == ["~", "secrets"])
    }

    @Test("NUL characters are rejected")
    func nulRejected() {
        #expect(throws: VFSError.self) { try VFSPath(normalizing: "/workspace/ios/a\0b", relativeTo: root) }
    }

    @Test("mount name and repository path")
    func mountSplit() throws {
        let path = try VFSPath(normalizing: "/workspace/ios/Sources/App.swift", relativeTo: root)
        #expect(path.mountName == "ios")
        #expect(path.mountPath == "Sources/App.swift")
        let mount = try VFSPath(normalizing: "/workspace/ios", relativeTo: root)
        #expect(mount.mountPath.isEmpty)
        #expect(VFSPath.root.mountName == nil)
    }

    @Test("appending and parent")
    func appendingAndParent() throws {
        let directory = try VFSPath(normalizing: "/workspace/ios/Sources", relativeTo: root)
        #expect(directory.appending("App.swift").description == "/workspace/ios/Sources/App.swift")
        #expect(directory.parent?.description == "/workspace/ios")
        #expect(VFSPath.root.parent == nil)
        #expect(directory.name == "Sources")
    }
}
