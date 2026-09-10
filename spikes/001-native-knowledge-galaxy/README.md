# Native Listen galaxy spike

## Verdict: PARTIAL

**Current build blocker after merging upstream `3d5f9ef`:** `bash verify.sh --ui` cannot reach the tests because the scoped ListenKit build omits the new `CloudRecords` dependency of `MemoryPreferences`. Earlier verification below predates that merge; it is not a passing result for the current branch. The last working executable can still export synthetic scenes. See the [follow-up checklist](FOLLOW_UP.md) for acceptance criteria and references.

The isolated AppKit + MetalKit vertical slice builds and renders on this Mac using Command Line Tools and runtime Metal shader compilation. It is not integrated into production Listen. The device-centered spherical-shell design is implemented in the standalone prototype, including a bounded one-shot force relaxation and Galaxy-inspired ambient rendering. Production integration and live Ask conversation ingestion remain outside this milestone.

Everything here is isolated from production Sources, the installed app, inference, consent, and library writes. The default is explicitly synthetic. Real-library access requires an explicit path.

## Run

From this directory:

```sh
bash build.sh
.build/ListenGalaxy
```

The native window supports drag-to-orbit, Shift-drag-to-pan, scrolling/pinch zoom, smooth selection focus, hover emphasis, reset, relationship inspection, and read-only evidence windows. Ambient rotation/twinkle uses a 30 fps visible-view budget and pauses during inspection, when hidden/occluded, with Reduce Motion, or in low-power mode. Pause/Resume is explicit. Reload refreshes the graph.

```sh
# Deterministic synthetic fixture; counts only, no private content
.build/ListenGalaxy --summary --nodes 1200

# Explicit read-only local-library access
.build/ListenGalaxy --library "$HOME/Library/Application Support/Listen"

# Tests, including actual synthetic native-window rendering and idle behavior
bash verify.sh --ui

# Synthetic offscreen PNG and measured rendering timings
.build/ListenGalaxy --nodes 1200 --probe results/probe-1200.png --frames 120

# Repeatable bounded shell benchmarks (80, 400, 1200 total nodes)
python3 benchmark.py

# Real-time synthetic GPU animation preview (requires Pillow + ffmpeg for encoding)
.build/ListenGalaxy --nodes 80 --export-frames results/shell-frames --frames 240
python3 render_preview.py
```

Generated binaries, images and measurements are under ignored `.build/` and `results/`. No installation, signing, network service, or full Xcode app is required for these commands. `Info.plist` is preparatory bundle metadata only; this spike currently launches as the standalone executable above.

## Verified results

- Core projection/layout suite passed: stable identity and positions, evidence topology, actual entry subjects, corrected object semantics, qualifiers/statuses, source-only graphs, and deduplication.
- Library suite passed: missing-library refusal without writes, typed source discovery, validated source links, live hides, source exclusions, proof invalidation, and safe evidence paths including symlink escape attempts.
- Camera and rendered-node picking tests passed.
- CLI tests passed: synthetic/live separation, an empty real library is not replaced by synthetic data, and invalid arguments fail.
- Revised native-window smoke passed with 2 rendered frames, successful selection, 1 evidence callback, and 0 additional frames in both paused and hidden half-second checks. macOS reported the test window as occluded, so continuous unoccluded window animation was not exercised; the test reports `motion_permitted: false` rather than claiming it ran. Actual time-varying GPU frame export separately passed. The harness now requires completion JSON, not merely exit code 0.
- Existing production `tools/verify_memory_core.sh` passed all 93 checks. A pre-existing ContextLedger trailing-closure compiler warning remains.
- Independent review is complete. Both reported blockers were fixed and passed final narrow re-review: focus flights now honor manual pause, visibility, Reduce Motion and low-power policy; cancelling a flight requests one settled-camera redraw and label refresh before remaining paused. The controller-level regression is included in `verify.sh`. No remaining security concerns or logic errors were reported in the reviewed scope. The visible-window presentation limitation below still applies.
- The explicit local-library read returned 95 source nodes and 19 source links, with 0 verified memory cards. This is a point-in-time observation, not an assertion that Listen has populated person/project memory here.
- GPU runtime shader compilation and actual offscreen PNG rendering succeeded on Apple M1 Max. The PNG background was checked after BGRA-to-RGBA conversion: RGBA (9, 13, 23, 255).

## Earlier cluster-fixture performance measurements

These measurements describe the initial synthetic cluster layout, NOT the newly requested spherical-shell design. All probes rendered at 1280 x 800 for 120 frames, including the first frame. Fixtures use sparse chain edges, not dense real-world relationship topology.

- 1,200 nodes / 1,199 edges: mean GPU 0.1282 ms; CPU submit-and-wait 0.3827 ms; whole-process peak RSS 37.80 MiB.
- 10,000 nodes / 9,999 edges: mean GPU 0.3938 ms; CPU submit-and-wait 0.6516 ms; whole-process peak RSS 46.00 MiB.
- 50,000 nodes / 49,999 edges: mean GPU 0.8379 ms; CPU submit-and-wait 1.1132 ms; whole-process peak RSS 98.17 MiB.

The earlier cluster raw values were saved in `results/benchmarks.json`. The current `benchmark.py` instead writes `results/shell-benchmarks.json` for the revised bounded scene. These are offscreen renderer timings, not screen FPS. They exclude AppKit label work, display compositing, startup shader compilation, and concurrent recording/transcription. Dense clusters overlap visually; large node-count throughput does not establish usability.

## Revised shell implementation and evidence

- Center: `view:current-device`, a presentation-only origin with no evidence or factual edges.
- Exact shell radii: people 5, notes 9, Ask conversations 13, recordings 17.
- Actual graph edges exert tangent-plane attraction. Local spatial repulsion and seed anchors resist overlap and wholesale movement. Relaxation runs once per snapshot, not every animation frame.
- Initial angular samples use an avalanche-mixed deterministic hash. Tests caught the unmixed FNV sector bias, live-source zero positions, and off-by-one total counts before acceptance.
- The overview is centered on the device rather than the bounding-box midpoint of uneven nodes.
- Background stars are decorative, round, and unpickable. Selection/hover radii and animated coordinates agree with picking. Spherical guide geometry is distinct from graph edges.
- The exported preview is 240 actual GPU-rendered frames, 1280 x 800, encoded at 30 fps into an 8-second MP4. It is not an OS screen recording or a view of private data. Title/legend are export overlays, not app chrome.
- Current benchmarks report 80, 400, and 1200 total nodes, including the center, with 59, 299, and 899 thematic synthetic edges. Use raw `results/shell-benchmarks.json`; results exclude UI labels, compositing and transcription.
- This presentation is capped at 1200 total nodes. Unsupported types and capacity omissions are disclosed in the scene label; underlying data is not changed.

## Current visual direction

The current rendering device's Listen instance is the center planet. Stars occupy concentric 3D spherical bands, inside outward: people, notes, Ask conversations, recordings. The central planet is a navigation anchor, not a factual ledger relationship to every item. See CONTRACT.md for the authoritative direction and unresolved treatment of other entity types.

## Limitations and follow-up

- Review the actual shell preview with the user. Verify continuous visible-window behavior interactively, since macOS marked the automated test window occluded. Old cluster benchmarks are not measurements of the revised scene.
- Ask conversation loading is not implemented. Verify actual storage and privacy semantics before representing real chats.
- Projects, organizations, topics, and claims remain underlying graph types; their placement in the revised presentation is undecided. Filters/contextual highlighting are a proposal only.
- Current evidence navigation opens verified text and displays an available recording offset. It does not yet seek playback in production Listen or guarantee a separate speaker field.
- The graph is a read-only snapshot refreshed by Reload. It is not a live-synced production view. Evidence access rechecks current sources and proofs.
- Closed evidence windows remain retained by the prototype's array; remove them on close before long-session use.
- Command-buffer allocation failure currently returns silently after successful renderer initialization. Surface runtime submission failures before production integration.
- Actual OS window screenshots were blocked by missing Screen Recording permission. Native rendering and UI callbacks were exercised programmatically; offscreen GPU images were inspected separately. Do not call the offscreen PNG an OS window screenshot.
- Full production Listen/MLX build, Xcode GPU profiling, macOS 14 deployment compatibility, iOS integration, and concurrent recording/transcription performance remain unverified. The scoped real-source ListenKit module is not a substitute for those tests.

## Recommendation

Keep MetalKit for this native experiment. Review the implemented shell/force/motion preview with the user before touching production application surfaces. Validate performance alongside actual recording/transcription and with populated provenance-backed data before production adoption.
