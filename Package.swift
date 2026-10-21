// swift-tools-version:5.9
import PackageDescription

// Command Line Tools ship neither XCTest nor the Swift Testing macros, so tests
// live in a plain executable: `swift run selftest`.
let package = Package(
    name: "mycroft",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "mycroft", targets: ["mycroft"])],
    targets: [
        // Thin C wrapper over onnxruntime (brew install onnxruntime) for the wake word and voiceprint models.
        .target(name: "COrt", cSettings: [.unsafeFlags(["-I/opt/homebrew/include/onnxruntime"])],
                linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"]), .linkedLibrary("onnxruntime")]),
        .target(name: "MycroftCore", dependencies: ["COrt"]),
        .executableTarget(name: "mycroft", dependencies: ["MycroftCore"]),
        .executableTarget(name: "selftest", dependencies: ["MycroftCore"]),
    ]
)
