// swift-tools-version:5.9
import PackageDescription

// Command Line Tools ship neither XCTest nor the Swift Testing macros, so tests
// live in a plain executable: `swift run selftest`.
let package = Package(
    name: "jarvis",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "jarvis", targets: ["jarvis"])],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(name: "jarvis", dependencies: ["JarvisCore"]),
        .executableTarget(name: "selftest", dependencies: ["JarvisCore"]),
    ]
)
