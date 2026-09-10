import AppKit
import Foundation
import ListenKit

struct GraphOptions {
    var root: URL?
    var nodes = 80
    var frames = 120
    var summary = false
    var history = false
    var probe: URL?
    var selectID: String?
    var exportFrames: URL?
    var still = false
    var smoke = false
    var quitAfter: Double?
    var help = false
    init(_ arguments: [String]) throws {
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw GraphCLIError.argument("Missing argument value") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--library": root = URL(fileURLWithPath: try value())
            case "--nodes":
                guard let number = Int(try value()), (4...1200).contains(number) else { throw GraphCLIError.argument("--nodes requires 4...1200") }; nodes = number
            case "--frames":
                guard let number = Int(try value()), (1...1000).contains(number) else { throw GraphCLIError.argument("--frames requires 1...1000") }; frames = number
            case "--probe": probe = URL(fileURLWithPath: try value())
            case "--export-frames": exportFrames = URL(fileURLWithPath: try value())
            case "--still": still = true
            case "--summary": summary = true
            case "--include-history": history = true
            case "--select": selectID = try value()
            case "--smoke-ui": smoke = true
            case "--quit-after":
                guard let seconds = Double(try value()), seconds.isFinite, seconds > 0 else { throw GraphCLIError.argument("--quit-after requires positive seconds") }; quitAfter = seconds
            case "--help", "-h": help = true
            default: throw GraphCLIError.argument("Unknown option: " + arguments[index])
            }
            index += 1
        }
        if smoke && root != nil { throw GraphCLIError.argument("UI smoke tests use synthetic data only") }
        if (probe != nil || exportFrames != nil) && root != nil { throw GraphCLIError.argument("GPU image probes use synthetic data only; private library images are not exported") }
    }
}

enum GraphCLIError: Error, LocalizedError {
    case argument(String)
    var errorDescription: String? { switch self { case .argument(let text): return text } }
}

@main struct GraphEntry {
    static func main() {
        do {
            let options = try GraphOptions(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print("""
                Listen native knowledge galaxy spike. No production app changes.
                Default: synthetic interactive graph.
                  --library PATH       Read-only real Listen library, no inference or migrations
                  --summary            Print counts only and exit
                  --nodes N            Synthetic total nodes including device (4...1200)
                  --include-history    Include historical/retracted memory, with labels
                  --probe OUTPUT.png   Offscreen synthetic GPU timing and PNG; not display FPS
                  --frames N           Measured probe frames (default 120)
                  --export-frames DIR  Synthetic animated GPU PNG sequence at 30 fps
                  --still              Start with ambient animation paused
                  --select NODE_ID     Initially select a node
                  --smoke-ui           Synthetic selection/evidence/idle smoke test and exit
                  --quit-after N       Close standalone viewer after N seconds
                """)
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try GraphBridge.load(root: options.root, nodeCount: options.nodes, includeHistory: options.history)
            let loadMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            var output: [String: Any] = ["nodes": result.snapshot.nodes.count, "edges": result.snapshot.edges.count,
                "synthetic": result.synthetic, "verified_cards": result.verifiedCards, "projection_present": result.projectionPresent,
                "skipped_sources": result.skippedSources, "load_and_layout_ms": loadMS,
                "nodes_by_kind": Dictionary(grouping: result.snapshot.nodes, by: \.kind).mapValues { $0.count }]
            if let directory = options.exportFrames {
                try GraphGPUProbe.exportFrames(snapshot: result.snapshot, directory: directory, count: options.frames, fps: 30)
                output["exported_frames"] = options.frames
                output["export_directory"] = directory.path
                output["note"] = "Synthetic actual Metal frame sequence. Not an OS screen recording."
                try printJSON(output); return
            }
            if let target = options.probe {
                output["offscreen_probe"] = try GraphGPUProbe.run(snapshot: result.snapshot, output: target, frames: options.frames)
                output["note"] = "Offscreen render submission + wait and GPU duration. Excludes AppKit labels, display compositing, audio/transcription, and startup compilation. Not screen FPS."
                try printJSON(output); return
            }
            if options.summary { try printJSON(output); return }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = GraphApp(options: options, loaded: result)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            fputs("ListenGalaxy: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

final class GraphApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: GraphOptions
    var loaded: GraphLoadResult
    var window: NSWindow!
    var graph: GraphViewController!
    var evidenceWindows: [NSWindow] = []
    var evidenceCallbacks = 0
    var reloadInFlight = false

    init(options: GraphOptions, loaded: GraphLoadResult) { self.options = options; self.loaded = loaded }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Listen Galaxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = menu
        graph = GraphViewController(snapshot: loaded.snapshot)
        graph.onEvidence = { [weak self] in self?.showEvidence($0) }
        graph.onReload = { [weak self] in self?.reload() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = loaded.synthetic ? "Listen Galaxy · SYNTHETIC prototype" : "Listen Galaxy · read-only local library"
        window.contentViewController = graph
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 800, height: 550)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.orderFront(nil)
        if options.still { graph.setMotionEnabled(false) }
        if let selected = options.selectID { graph.select(nodeID: selected) }
        if let seconds = options.quitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) } }
        if options.smoke { runSmoke() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !options.smoke }

    func reload() {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        let options = options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try GraphBridge.load(root: options.root, nodeCount: options.nodes, includeHistory: options.history) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reloadInFlight = false
                switch result {
                case .success(let loaded): self.loaded = loaded; self.graph.update(snapshot: loaded.snapshot)
                case .failure(let error):
                    self.graph.update(snapshot: GraphSnapshot(nodes: [], edges: [], label: "Read failed. Stale graph cleared."))
                    self.showText(title: "Library read failed", text: error.localizedDescription)
                }
            }
        }
    }

    func showEvidence(_ evidence: GraphEvidence) {
        evidenceCallbacks += 1
        guard let root = options.root else {
            showText(title: "Synthetic evidence", text: "SYNTHETIC FIXTURE ONLY\nNo recording or source file is represented.\n\n" + evidence.title + "\n\n" + evidence.quote)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<String, Error> = Result {
                let current = try GraphLibrary.read(root: root)
                if !evidence.quote.isEmpty {
                    let live = current.cards.flatMap(\.entries).flatMap { $0.evidence + ($0.changeEvidence ?? []) }
                    guard live.contains(where: { $0.source == evidence.source && $0.quote == evidence.quote && $0.start == evidence.start }) else { throw GraphLibrary.Problem.sourceUnavailable }
                }
                let source = current.sources.first { $0.id == evidence.source }
                guard let path = evidence.relativePath ?? source?.relativePath else { throw GraphLibrary.Problem.sourceUnavailable }
                let url = try GraphLibrary.evidenceURL(source: evidence.source, relativePath: path, root: root)
                let bytes = try GraphLibrary.boundedData(url)
                let text = String(decoding: bytes, as: UTF8.self)
                let time = evidence.start.map { "\nRecording offset: \($0) seconds" } ?? ""
                return evidence.title + time + "\nSource: " + path + "\n\n" + (evidence.quote.isEmpty ? text : "Supporting quote:\n" + evidence.quote + "\n\nCurrent source file:\n" + text)
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let text): self?.showText(title: "Source evidence · read-only", text: text)
                case .failure(let error): self?.showText(title: "Evidence unavailable", text: error.localizedDescription); self?.reload()
                }
            }
        }
    }
    func showText(title: String, text: String) {
        let detail = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let body = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        body.isEditable = false; body.isSelectable = true
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.textContainerInset = NSSize(width: 16, height: 16)
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.string = text
        scroll.documentView = body
        detail.title = title; detail.contentView = scroll; detail.isReleasedWhenClosed = false
        detail.center(); detail.orderFront(nil)
        evidenceWindows.append(detail)
    }
    func runSmoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let target = loaded.snapshot.nodes.first(where: { !$0.evidence.isEmpty }) else { fatalError("Synthetic smoke fixture needs evidence") }
            graph.select(nodeID: target.id)
            guard graph.selectedID == target.id else { fatalError("Selection did not update") }
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            guard let button = buttons(graph.view).first(where: { $0.title == target.evidence[0].title }) else { fatalError("Evidence button was not rendered") }
            button.performClick(nil)
            guard evidenceCallbacks == 1 else { fatalError("Evidence callback was not delivered") }
            graph.setMotionEnabled(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                let baseline = graph.renderedFrameCount
                guard baseline > 0 else { fatalError("Native viewer never rendered") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    let idleFrames = graph.renderedFrameCount - baseline
                    guard idleFrames == 0 else { fatalError("Paused viewer is still rendering") }
                    graph.select(nodeID: nil)
                    graph.setMotionEnabled(true)
                    evidenceWindows.forEach { $0.orderOut(nil) }
                    window.orderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                        graph.refreshMotionPolicy()
                        let activeBaseline = graph.renderedFrameCount
                        let permitted = graph.animationRunning
                        let motionPolicy = graph.motionDiagnostics
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                            let animatedFrames = graph.renderedFrameCount - activeBaseline
                            if permitted { guard animatedFrames > 0 else { fatalError("Enabled visible animation did not render") } }
                            window.orderOut(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                                let hiddenBaseline = graph.renderedFrameCount
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                                    let hiddenFrames = graph.renderedFrameCount - hiddenBaseline
                                    guard hiddenFrames == 0, !graph.animationRunning else { fatalError("Hidden viewer is still animating") }
                                    try? GraphEntry.printJSON(["ui_smoke": "passed", "selection": true, "evidence_callbacks": evidenceCallbacks,
                                        "rendered_frames": baseline, "paused_frames_over_half_second": idleFrames,
                                        "motion_permitted": permitted, "motion_policy": motionPolicy, "animated_frames_over_half_second": animatedFrames,
                                        "hidden_frames_over_half_second": hiddenFrames, "synthetic": true])
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
