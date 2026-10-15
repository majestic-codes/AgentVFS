// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentVFS",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AgentVFS", targets: ["AgentVFS"]),
        .library(name: "AgentVFSSQLite", targets: ["AgentVFSSQLite"]),
        .library(name: "AgentVFSJQ", targets: ["AgentVFSJQ"]),
        .library(name: "AgentVFSPDF", targets: ["AgentVFSPDF"]),
        .library(name: "AgentVFSTools", targets: ["AgentVFSTools"]),
        .library(name: "AgentVFSAPI", targets: ["AgentVFSAPI"]),
        .executable(name: "vfsh", targets: ["vfsh"]),
    ],
    targets: [
        .target(name: "AgentVFS"),
        .target(name: "AgentVFSSQLite", dependencies: ["AgentVFS"]),
        .target(name: "AgentVFSJQ", dependencies: ["AgentVFS"]),
        .target(name: "AgentVFSPDF", dependencies: ["AgentVFS"]),
        .target(name: "AgentVFSTools", dependencies: ["AgentVFS", "AgentVFSSQLite", "AgentVFSJQ", "AgentVFSPDF"]),
        .target(name: "AgentVFSAPI", dependencies: ["AgentVFS", "AgentVFSJQ"]),
        .executableTarget(name: "vfsh", dependencies: ["AgentVFS", "AgentVFSTools"]),
        .testTarget(name: "AgentVFSTests", dependencies: ["AgentVFS"]),
        .testTarget(name: "AgentVFSSQLiteTests", dependencies: ["AgentVFSSQLite"]),
        .testTarget(name: "AgentVFSJQTests", dependencies: ["AgentVFSJQ"]),
        .testTarget(name: "AgentVFSPDFTests", dependencies: ["AgentVFSPDF"]),
        .testTarget(name: "AgentVFSAPITests", dependencies: ["AgentVFSAPI", "AgentVFSJQ"]),
    ]
)
