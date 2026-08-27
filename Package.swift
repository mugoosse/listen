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
        // Pinned to a revision rather than `branch: "main"`: the branch form
        // re-resolves to whatever main holds on the day of the build, which
        // makes a release unrepeatable and hands the update channel of this
        // dependency to anyone who can push to it. Move the pin deliberately.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git",
                 revision: "4266f988d170a83017d1e82e2e4654602f277f1d"),
        // Diarization and speaker embeddings, CoreML on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.4"),
        // Opt-in analytics and crash reports; Telemetry.swift is the only
        // importer and TELEMETRY.md is the contract. Pinned exactly for the
        // same reason mlx-audio is: an analytics SDK that can update itself
        // under a release is exactly the dependency to move deliberately.
        // The iOS app pins the same version through tools/make_xcodeproj.py.
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.69.12"),
        // Present transitively through mlx-audio-swift, declared explicitly so
        // we can drive the model download ourselves and get a progress
        // callback: STT.loadModel does not forward one.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    ],
    targets: [
        // The half both apps share: the folder contract, the sealing and the
        // sync. MIT rather than AGPL, and `Sources/ListenKit/LICENSE` says why.
        // Listen for iPhone compiles these same files, so this is one copy with
        // two consumers rather than two copies that have to be kept agreeing.
        //
        // It deliberately depends on nothing. Every dependency here would have
        // to build for iOS too, and the point of this target is that it is
        // plain logic over files, testable from a command line on either
        // platform without a simulator.
        .target(name: "ListenKit", path: "Sources/ListenKit",
                exclude: ["LICENSE"]),
        .executableTarget(
            name: "listen",
            dependencies: [
                "ListenKit",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "PostHog", package: "posthog-ios"),
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
