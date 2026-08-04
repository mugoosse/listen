// swift-tools-version: 5.9
import PackageDescription

// One executable, argument-dispatched, rather than separate app and CLI
// targets. The CLI, the MCP server and the app all read the same library on
// disk, and splitting them would mean two code paths over that library which
// have to be kept agreeing. FluidAudio arrives with milestone 3; there is no
// point resolving a dependency nothing imports yet.
let package = Package(
    name: "listen",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        // Diarization and speaker embeddings, CoreML on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.4"),
        // Present transitively through mlx-audio-swift, declared explicitly so
        // we can drive the model download ourselves and get a progress
        // callback: STT.loadModel does not forward one.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "listen",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/listen",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                // Sparkle ships as a binary framework, and SwiftPM does not
                // embed frameworks into a bare executable. make_app.sh copies
                // it into Contents/Frameworks, so the runtime search path has
                // to point there or the app dies at launch with a dyld error.
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
