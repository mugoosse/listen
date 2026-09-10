# The galaxy

The library drawn as concentric shells around this Mac. `Galaxy`,
`GalaxyRenderer`, `GalaxyCamera`, `GalaxyMotion`, `GalaxyMotionPolicy`,
`GalaxyPane`, `GalaxyInspector`, `LibraryWindow.Mode.galaxy`, `listen galaxy`,
`verify_galaxy.sh`.

It began as `spikes/001-native-knowledge-galaxy`, an isolated AppKit and
MetalKit prototype with its own build script, its own scoped copy of ListenKit
and its own synthetic fixture. That directory is gone: the renderer, the camera
and the motion policy came into `Sources/listen/` and the data half was
replaced outright, because the app already holds `Recording`, `Note`, `Person`
and `Chat` in process and the spike had been going through the memory-card
projection to reach them. The measurements below that predate the merge say so.

## What the picture claims

- **The centre is this Listen instance, and it has no edges.** A line from the
  centre to every star would be a claim that this Mac stands in some relation
  to each of them, and the only true version of that sentence is "they are in
  the library", which the picture already says by drawing them. `GalaxyScene`
  drops any edge touching `Galaxy.deviceID` rather than trusting callers not to
  make one, and `verify_galaxy.sh` asserts `centre_edges == 0`.
- **Radius is a category and nothing else.** People 5, notes 9, chats 13,
  recordings 17. Encoding importance in the radius was the obvious next idea:
  there is no measure of importance in this library that is not a guess, and a
  guess drawn as a distance reads as a fact. Recency has the same problem with
  an extra one, which is that the picture would rearrange itself weekly and
  nobody could learn where anything is.
- **Every edge is a row somebody can go and read.** A note names its
  recordings, a conversation names the meetings it was asked about, a person is
  a speaker in a transcript. Three kinds, and the script asserts that no fourth
  appears: a similarity edge, a co-occurrence edge or a "these happened the
  same week" edge would each show up as one.
- **The cap is disclosed, never silent.** 1200 stars, and the label says how
  many are missing. Measured on a synthetic 1300-recording library: 1194
  recordings, 5 people, the centre, and "106 stars are not drawn".

## Things that will bite you

### A hand-picked list of ListenKit files is a list upstream will break

The spike compiled eight named ListenKit sources into a module of its own so it
could build with `swiftc` and Command Line Tools, no Xcode and no MLX. It broke
twice, both times on an upstream commit that added no API the spike called:
`MemoryPreferences` grew a reference to `CloudRecords`, and swiftc needs that
declaration in scope for a function nothing in the spike invokes.

Chasing the closure by hand does not converge. Adding `CloudRecords.swift`
asks for `Recording`, `DevicePolicy` and `StoredRecord`; adding those asks for
`PairingKey`. `Sources/ListenKit` is 34 files that deliberately depend on
nothing outside Foundation (see `Package.swift`), so the whole module compiles
standalone, and compiling all of it is the only version of that list an
upstream edit cannot invalidate. Measured on an M1 Max: 185 s at `-O`, 115 s at
`-Onone`, about 2 s once the result is cached against a hash of the sources.

`tools/verify_memory_core.sh` had exactly the same bug from exactly the same
commit and was failing on `main` before any of this. It builds the whole module
now too.

### A public struct's memberwise initialiser is internal

`MemoryPreferences.Value` is `public`, and `tools/verify_memory_core.swift`
could name it from outside ListenKit but never build one: the synthesised
`init(text:updated:)` is internal. It had never come up because the harness
used to compile the ListenKit sources into its own module rather than import
one. Anything public that a consumer has to construct needs the initialiser
written out.

### An app that never activates itself calls its own window occluded

The ambient motion is gated on the window being visible, and visibility reads
`occlusionState.contains(.visible)`. macOS reports an *inactive* app's window
occluded, and the prototype only ever called `orderFront`. So the galaxy opened
with its motion paused, on a window that was plainly on screen, and every
automated run recorded `motion_permitted: false` and shrugged.

`makeKeyAndOrderFront` plus `NSApp.activate` fixed it, and the number moved
from 0 rendered frames in half a second to 16, which is the 30 fps budget. The
test that reported it and skipped is the reason it survived: a check that
excuses itself has to name the excuse, so `verify_galaxy.sh` fails unless the
trace says Reduce Motion or Low Power.

### What the GPU is doing is invisible to accessibility and to a screenshot

The stars are one `MTKView`, so there is nothing in the accessibility tree to
click and nothing in a still image that says whether frames are being drawn.
Two things stand in: `LISTEN_PANEL=galaxy:selected` opens with a star already
picked, which is the only way a probe reaches the inspector card, and the
motion policy writes one `LISTEN_DEBUG` line per transition naming every gate.
`verify_search.sh` reads a scroll position out of the trace for the same
reason.

### A locked screen photographs as black, and answers nothing

`screencapture` returns a black image rather than an error when the screen is
locked, which is the same family as a sleeping display emptying the AX tree.
Check `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked` before
believing a picture, and before believing a UI run that "passed".

### A wrapping label demands its whole string as one line

`NSTextField(wrappingLabelWithString:)` in a leading-aligned `NSStackView`
reports its entire string as one line's worth of fitting width. The stack
passes that up, and in the prototype the split view handed the detail panel two
thirds of a 1180-point window because of one paragraph of legend text: the
galaxy was clipped by a sentence. A width constraint against the stack is what
makes it wrap; a resting width constraint on the panel, at less than required
priority, is what stops the split view listening to it at all.

### An `NSClipView`'s origin is at the bottom

A document view shorter than its scroll view sits at the *bottom* of it. The
prototype's detail panel opened with its heading two thirds of the way down an
empty column, which reads as a rendering failure rather than as a scroll
position. A flipped `NSClipView` subclass fixes it, and it has to be installed
before the document view or the scroll view re-parents the document into the
old one.

### A character count is not a width

`min(155, max(65, title.count * 5.5))` asked for 66 points for "Casey Wright"
and the label drew "Casey Wri…". Only the cap should ever shorten a title, so
the width is measured with the font that will draw it.

### Rank the labels on the position the star is drawn at

The ambient rotation is applied on the GPU through the uniform `model` matrix,
and `GalaxyMotion.position` is what the CPU uses to agree with it. The label
pass projected the rotated position and then sorted the candidates by the
*unrotated* one, so the two dozen titles were chosen from a different set than
the two dozen stars in front. Picking has the same requirement and gets it
right for the same reason: one function, three callers.

### `turns.json` is a bare array

`People.speakers` decodes `[Turn]`, not `{"turns": [...]}`. A fixture written
in the second shape produced a library where every recording had a title, a
date and a duration, and nobody spoke in any of them. The galaxy drew 62 stars
and 0 people and looked entirely plausible. `verify_galaxy.sh` asserts the
person count for exactly this reason.

### Adjacent ids land in one band of the sphere without an avalanche mix

The seed angle comes from FNV-1a over the id, which is fixed across launches
where Swift's own `Hasher` is deliberately not. Raw FNV over ids that differ in
their last character returns values that differ only in their low bits, so
taking `z` from those put a whole library into one latitude band. Two
avalanche-mixed draws per id, one for `z` and one for the angle.

### Repulsion acts across shells, on purpose

The relaxation pushes apart *unit directions*, not positions, so a person at
radius 5 and a recording at radius 17 in the same direction repel each other.
That reads as wrong until you look at the picture without it: two stars on the
same ray overlap from almost every camera angle, and the shells grow visible
spokes. Everything is renormalised onto its own radius at the end of each pass,
so nothing can leave its shell however hard it is pushed.

### A failed command buffer used to be a silent return

`makeCommandBuffer()` returning nil after a successful renderer init left the
window on its last frame with nothing said, which is indistinguishable from a
paused galaxy. It reports through `onError` now, which pauses the motion and
puts the sentence on the pane. A zero viewport is still a silent return,
because that is a view awaiting layout rather than a failure, and reporting it
would fire on every launch.

### `mouseUp` must compare against where the press started

`dragOrigin` is moved to the current point on every drag event, so comparing
the mouse-up location with it finds them a pixel apart at the end of any drag
and calls it a click. The press location is kept separately.

### The sidebar stays live, so a row picked there has to leave the mode

Settings and chat replace the sidebar's list because theirs is a different
list. The galaxy is drawn from the same recordings the sidebar is showing, so
taking the list away would hide the answer to "which of these is that star".
The cost is that `sidebar.onSelect` can fire while the mode is `.galaxy`, and
it swaps `detailHost` directly: without a guard the transcript appears under a
toolbar and a composer that both still believe they are over a galaxy. `enter`
is a no-op on the mode it is already in, so the guard costs a comparison.

### The shader is compiled from source, not added to the build

`device.makeLibrary(source:)` at renderer init, about 40 ms once. A `.metal`
file in the target would mean the galaxy could only be built through the full
Xcode path, in an app that already fights one metallib problem (see CLAUDE.md,
"`swift build` does not produce a working binary"), and it would put the shader
in a second place from the code that sets its uniforms.

## Measurements

- Snapshot build, end to end including process launch, on the real library
  (76 recordings, 19 notes, 27 chats, 32 people, 177 links): **50 ms**, three
  runs, `listen galaxy`.
- The same on a synthetic 1300-recording library with 40 turns each:
  **380 ms**, three runs. That is the read and the layout; the cap means only
  1200 stars reach the renderer.
- Visible-window ambient motion: **16 frames per half second** against a 30 fps
  budget, five consecutive runs of the prototype's smoke test, all 16.
- Paused, hidden and Reduce Motion each render **0** frames per half second.
- Offscreen renderer timings, from the prototype and **not** re-measured since
  the merge: at 1280x800 over 120 frames, 1200 nodes was 0.128 ms mean GPU and
  0.383 ms CPU submit-and-wait; 10,000 nodes was 0.394 ms and 0.652 ms; 50,000
  was 0.838 ms and 1.113 ms. These exclude AppKit labels, display compositing
  and any concurrent transcription, so they are not frame rates.

## What is deliberately not here

- **No inferred edges.** No similarity, no co-occurrence, no "these happened in
  the same week". The three relationships drawn are the three the library
  writes down.
- **No importance, and no recency, in the radius.** See above.
- **No topics, projects or claims.** The person-context store holds them
  (`.agents/notes/person-context.md`), and they are not one of the four kinds
  of thing the library is made of. Putting them on a fifth shell would say they
  are a peer of a recording; putting them on an existing one would say they are
  a note. Filters or a contextual highlight are the shape worth trying, and
  neither is designed yet.
- **No editing.** Every verb is on the page the star opens.
- **No second read of the library.** The pane calls `Galaxy.build` on a
  background queue and coalesces requests: the window reloads on activation, on
  a recording arriving and on the queue advancing, and three passes for one
  visible change is three passes nobody asked for.
