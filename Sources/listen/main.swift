import AppKit

// The CLI and the app are the same binary. Argument dispatch happens before
// anything AppKit-shaped is created, so `listen transcribe` needs no
// permissions and does not put a menu bar item on screen for the length of a
// transcription.
if CLI.wants(CommandLine.arguments) {
    await CLI.run(CommandLine.arguments)
}

// Top-level code in main.swift is already main-actor isolated, so the App can
// be constructed directly. Wrapping this in MainActor.assumeIsolated is an
// error under Swift 6: assumeIsolated is unavailable from an async context, and
// the `await` above makes this one.
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
// NSApplication holds its delegate weakly, so keep a strong reference.
objc_setAssociatedObject(app, "listen.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
app.run()
