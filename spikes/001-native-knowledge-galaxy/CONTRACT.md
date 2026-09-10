# Native knowledge galaxy spike contract

Isolated experiment on branch spike/native-knowledge-galaxy. No changes to production Sources, installed Listen, primary library, consent, or inference. No external services. Build with swiftc and runtime Metal shader compilation (not a production Listen/MLX build).

## Updated visual direction

User-defined layout: the center planet represents the current Listen app instance on the current device, not the user's person entity and not a Hermes agent. The app rendering the galaxy is always the center, whether on Mac or iOS. This is a presentation/navigation anchor, not a ledger entity, ownership claim, or factual edge to every item.

Stars occupy concentric three-dimensional spherical bands, ordered from inside to outside:

1. People
2. Notes
3. Ask chat conversations
4. Recordings

Band distance encodes content type, not inferred importance, relationship strength, ownership, or recency. Preserve stable positions and actual evidence-backed edges across bands. Do not substitute flat rings for spherical bands. The user explicitly approved Galaxy-like ambient movement. Animate only while visible with motion enabled, honoring Reduce Motion and low-power mode. Pause when hidden and during inspection/interaction. Ambient twinkle/orbit does not imply live source activity. Paused and hidden modes must render no continuous frames.

Projects, organizations, topics, and claims remain valid underlying graph data. Their visual treatment is not yet user-specified; filters/contextual highlighting are a proposed approach, not an approved additional shell. Do not silently misclassify them as people or source types. Ask conversation source loading must be verified against actual Listen storage and privacy rules before representing real chats.

This direction supersedes the initial hash-cluster visual experiment. The revised shell/force/motion implementation requires fresh tests and actual GPU images before acceptance. Existing performance measurements describe the earlier synthetic cluster fixture, not this revised presentation.

## Shared Swift interface (owned by graph-core agent)

All structs Codable, Sendable. Internal visibility is sufficient; compile all spike Swift files together. Import ListenKit for existing domain types.

- GraphEvidence: source: String, title: String, quote: String, start: Double?, relativePath: String? (library-relative file, never arbitrary URL).
- GraphNode: id: String, kind: String (person/project/organization/topic/recording/note/chat/claim/device); device is a presentation anchor only, title: String, position: SIMD3<Float>, evidence: [GraphEvidence].
- GraphEdge: id: String, source: String, target: String, kind: String (relationship/evidence/source-link/derived-speaker), label: String, status: String, evidence: [GraphEvidence].
- GraphSnapshot: nodes: [GraphNode], edges: [GraphEdge], label: String. Immutable value passed to renderer. IDs are stable, position not identity. No fields with hidden required initializers.
- GraphProjection.build(cards: [ContextCard], sources: [GraphNode] = [], sourceEdges: [GraphEdge] = [], includeHistory: Bool = false) -> GraphSnapshot. Only already verified cards may enter. Preserve polarity/modality/attribution in labels; corrected relationship text must not silently assert stale object identity. Do not draw similarity as factual relationship. No orphan nodes from filtered hidden/history-only claims. Evidence preserved.
- GraphLayout.apply(to: GraphSnapshot) -> GraphSnapshot. Stable hash-seeded cluster layout, independent of input ordering or node count, finite positions.
- GraphFixture.make(nodeCount: Int = 80) -> GraphSnapshot. Label must say synthetic. At least relationships, recording/note evidence, person/project kinds; deterministic; explicit no real source evidence files unless generated separately.

## Renderer interface (owned by renderer agent)

GraphViewController: NSViewController
- init(snapshot: GraphSnapshot)
- func update(snapshot: GraphSnapshot)
- var onEvidence: ((GraphEvidence) -> Void)?
- var onSelection: ((String?) -> Void)?

AppKit MTKView GPU-instanced rendering, batched edges, limited AppKit labels, orbit/zoom/pan/reset, click selection and detail panel with evidence buttons. Shader compiled with device.makeLibrary(source:options:). Surface errors, no silent fallback/mock renderer. Visible ambient mode may render continuously at a bounded frame rate; paused/hidden/reduced-motion mode must be event-driven. Data and camera updates invalidate. Add GPU offscreen probe API if possible:
- GraphGPUProbe.run(snapshot: GraphSnapshot, output: URL, frames: Int) throws -> [String: Double] (offscreen PNG and actual CPU/GPU timing, explicitly not screen FPS). Parent may adapt probe interface after report.
Do not implement executable @main or graph domain types; parent owns entry point, build script, library loader. Renderer agent owns files prefixed GraphRenderer/GraphView/GraphGPU, including tests.

## Library and entry point (parent)

Parent builds actual dependency-free ListenKit module with swiftc, then spike binary. Load verified cards via ContextSync.readCards(root:) and typed recording/note artifacts where feasible. Explicit --library path, no default private library in UI. Default synthetic graph. CLI summary shows counts only, no private titles/quotes. Parent owns standalone AppKit entry point, safe read-only source/evidence navigation, run/build commands, aggregate verification and results.

## Verification

TDD for graph semantics/layout/projection and camera/picking logic. Demonstrate RED then GREEN. Isolated fixture directories only. Test privacy invalidation/excluded notes via ListenKit current read gates. Do not fabricate content or metrics. GUI screenshots use synthetic data only. Actual library read path must report empty/partial state honestly. No commits/pushes by children.
