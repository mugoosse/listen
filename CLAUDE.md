# Listen: working notes for coding agents

Local meeting recorder, transcriber and speaker labeller for macOS. Pure Swift,
fully local. Read `README.md` for user-facing behaviour and `SPEC.md` for the
brief. This file is about working on the code without re-learning things the
hard way.

Speak (`../speak`) is the template. Its `CLAUDE.md` is a list of traps already
paid for and most of them still apply here; this file records the ones that are
Listen's own.

## Build and run

**`swift build` does not produce a working binary.** It links, then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Always use the scripts:

```sh
./build.sh      # xcodebuild wrapper, checks the Metal toolchain first
./make_app.sh   # wraps the binary in a signed .app
./install.sh    # both, then installs to /Applications and relaunches
```

One-time setup on a new machine:

```sh
xcodebuild -downloadComponent MetalToolchain    # ~688 MB, separate in Xcode 26
```

`-skipPackagePluginValidation` is required because mlx-swift ships a `CudaBuild`
plugin Xcode refuses to run unattended. It is a no-op on Apple Silicon.

### Verifying a change without the GUI

```sh
Listen.app/Contents/MacOS/Listen transcribe some.wav
Listen.app/Contents/MacOS/Listen transcribe some.wav --format json   # timings
```

Needs no permissions, so it separates a model problem from a capture problem
before anyone touches UI code. `--format json` is the one that shows timings,
which is what most questions about the pipeline are really about.

`LISTEN_DEBUG=1` traces capture state changes to stderr.
`LISTEN_CHUNK=<seconds>` overrides the ASR chunk length; `0` means decode the
whole file in one pass. It exists for the measurement below, not for users.

### The scheme has to exist before the first build

The first `./build.sh` on a fresh clone fails with `does not contain a scheme
named listen` even though `.swiftpm/.../listen.xcscheme` is committed.
xcodebuild registers the scheme only after the package graph resolves, and the
first run does both at once. Running it a second time works. This is why the
scheme is committed rather than generated: on a clean CI checkout xcodebuild
cannot write one, and the build fails permanently instead of on the first try.

## Things that will bite you

### mlx-audio does not expose word timings, only sentences

**This is load-bearing for speaker assignment.** SPEC section 4.4 assigns each
word to the overlapping speaker turn and splits a segment where the speaker
changes mid-sentence. Both need word timings.

The Parakeet decoder computes them. `NemoAlignedToken` carries `start` and
`duration` per sub-word token, finer than word level, and `NemoAlignedSentence`
keeps the whole token array. But `NemoAlignedResult.segments`, the only thing
that reaches `STTOutput`, projects each sentence down to `text`, `start` and
`end` and drops the tokens:

```swift
public var segments: [[String: Any]] {
    sentences.map { ["text": $0.text, "start": $0.start, "end": $0.end] }
}
```

`ParakeetModel` has exactly three public entry points, `generate`,
`generateBatch` and `generateStream`, and all three return `STTOutput`.
`decodeChunk`, which returns the aligned result, is `private`. So the
information exists and is thrown away one layer below where we can reach it.
Checked against upstream `main`, not just the pinned revision.

`ASR.segments(from:)` therefore reads a `words` key if one is ever present
rather than assuming it is not, and `Transcript.hasWordTimings` reports the
answer instead of anyone guessing. The CLI says so on every run. Do not build
word-level assignment on this until the exposure question is settled.

### One word is corrupted at every ASR chunk seam

Measured on synthesised speech numbering 60 sentences, so every word is
checkable:

| `LISTEN_CHUNK` | seams | result |
|---|---|---|
| 0 (whole file) | 0 | 60 sentences, in order, nothing missing or duplicated |
| 120 | 1 | sentence 56 came back as "number 50" |
| 60 | 2 | sentences 29 and 55 came back as "number 20" and "number 50" |

Exactly one corruption per seam, at the seam. The corrupted segment is also
short: 1.2 s against about 2.2 s for its neighbours, so the tail of the word
straddling the boundary is being dropped rather than mistranscribed.

mlx-audio chunks internally with a 2 second overlap and merges token sequences
on the longest contiguous match (`NemoAlignment.mergeLongestContiguous`). The
overlap is not enough to protect a word sitting on the boundary.

This matters more here than in Speak because a dictation is one chunk and a
meeting is not: at 120 s chunks an hour-long recording has 29 seams and
therefore about 29 corrupted words. Do not treat it as noise.

The principled fix is to cut chunks at silence rather than at a fixed offset,
so no word ever straddles a seam. mlx-audio ships `MLXAudioVAD`, so the parts
exist. Until then the chunk length is a trade against memory, measured below.

### The cache root is not always `~/.cache/huggingface`

Inherited wholesale from Speak, and the reason models are shared between the
two apps for free. swift-huggingface resolves `HF_HUB_CACHE`, then `HF_HOME` +
`/hub`, then the standard path. `ModelChoice.hubRoot` repeats those rules
exactly, including the sandbox branch Listen does not currently take.

Speak shipped the disagreement once: it measured the standard path, reported
"already downloaded", then sat on "loading model" for four minutes while the
library fetched 2.4 GB into the other cache, with no progress bar because as
far as Speak knew nothing was being downloaded.

This machine has `HF_HOME=/Users/mgo/ComfyUI/.cache/huggingface` set, and
Parakeet v2 is now in **both** caches, 4.6 GB in each, which is what paying for
this bug looks like. A Finder launch inherits no shell environment, so it does
not reproduce from the GUI. `env -u HF_HOME` when testing from a terminal, or
expect a surprise download.

### mlx-audio prints to stdout, and stdout is the transcript

`ModelUtils.resolveOrDownloadModel` prints `Using cached model at: <path>`
with a bare `print()` and no flag to suppress it, and `STT.loadModel` resolves
the model again internally, so it lands three times. On the CLI that is three
lines of library chatter in the middle of piped output.

`withStdoutOnStderr` dups stdout to stderr around model loading. It is safe
only because loading is serialized by the `ASR` actor and nothing else in the
process writes to stdout while it runs.

### An unknown command must not launch the app

`CLI.wants` treats any bare first argument as the CLI, including one it does
not recognise, so `listen bogus` says so and exits 1. Gating on the known list
instead meant an unrecognised command fell through to `NSApplication.run` and
hung the terminal, which reads as the binary being broken rather than the
command being wrong.

Anything starting with `-` that is not one of ours still falls through to
AppKit on purpose: launch services and Xcode pass their own flags (`-psn_0_…`,
`-NSDocumentRevisionsDebugMode`), and refusing to start because of one would
break launching the app entirely.

### Signing decides whether permissions survive a rebuild

Straight from Speak, and it matters more here. Ad-hoc signing gives a
designated requirement of `cdhash H"…"`, pinned to one build, so **every
rebuild silently invalidates the permission** while System Settings still shows
the toggle on. On an app that records hour-long meetings, that failure is
expensive. `make_app.sh` signs with a real certificate when one exists.

```sh
codesign -d -r- /Applications/Listen.app     # must not contain cdhash
```

### Sparkle has no keypair yet

`make_app.sh` omits `SUFeedURL` and `SUPublicEDKey` entirely unless
`SPARKLE_PUBLIC_KEY` is set. Sparkle then refuses to update rather than
accepting anything, which is the safe failure. The keypair is generated with
the rest of the release pipeline at milestone 9. Shipping a placeholder key
would be the dangerous option.

The framework is still linked, embedded and signed from milestone 0 so that the
rpath and the inside-out nested signing are exercised from the start. Both are
things you want to discover early, not during a release.

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong.
  Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip.
- Prefer measured numbers to remembered ones. Every threshold and size that came
  from a measurement says so.

## Testing

There is no test target, matching Speak. Verification is manual through the CLI
plus debug tracing. If you add one, note that MLX needs the Metal toolchain, so
tests must run through `xcodebuild`, not `swift test`.
