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

`listen galaxy --image` is the way round it: Metal needs no display, so the
scene renders to a PNG on a machine whose window server will not hand over a
pixel. It draws stars, links and the shell guides and **no titles**, because
the labels are AppKit text fields over the scene rather than anything the GPU
draws, which is what makes it safe to write one out of a real library.
`tools/pngstats.py` decodes the result without Pillow, and counts how many
pixels fall in each shell's colour: that is what proves a shell is drawn at
all, and it is the check that caught the layout collapsing into one hemisphere
while every count-based assertion still passed.

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

### You are the centre, and that is one star rather than two

The centre began as a synthetic anchor with no id and no edges, on a rule
worth keeping: a presentation anchor must not appear to stand in a
relationship to everything around it. What that produced on a real library was
two stars for one person, a huge `Me` hub out on the people shell with a line
to almost every recording, and an empty planet in the middle carrying no
evidence at all. The one in the middle was the falsehood.

So the centre is the user's own person node, promoted out of the shells to the
origin, keeping its id: clicking it opens your own page. The lines leaving it
are the same "speaks in" rows every other person's lines are. The rule is
intact and now says something sharper: **`Galaxy.deviceID` may never be an
endpoint**, because that id stands for nothing on disk. It is only used when
the library has never heard you speak, which is a first run or a library of
imported recordings nobody has labelled, and `verify_galaxy.sh` asserts both
cases.

The star is labelled with your name. "(this Mac)" belongs to the legend, where
a reader is asking what the centre *is* rather than who it is; putting it in
both made them disagree, because a promoted person kept their own name and the
anchor carried the bracket.

### The inspector card is painted, not blended, and its way out is a cross

**A `.sidebar` material is not how you match the sidebar.** It was the obvious
move and it is wrong: vibrancy blends with what is behind it, and behind this
card is the Metal view rather than the desktop, so the card rendered
RGB(38,38,45) beside a sidebar rendering RGB(11,15,28). `Brand.canvas` is what
the sidebar resolves to, so the card is simply painted that — which leaves it
the same colour as the scene, and a border and a shadow are what make it a card
rather than a hole. Measured after: both sides RGB(11,15,28).

The title leads and is the largest thing on it. It was third, under a "PERSON"
header in small caps, which spent the top line on the one word a reader can
already tell from the star's colour; the kind moved into the line below, as
"Recording · 1 May 2026 at 15:00 · 51:06".

Its dismiss was a "Clear" button beside Open, which read as a second verb on
the thing being described rather than as putting the card away, and gave the
two the same weight. It is a round glass cross in the corner now, where every
other page in this window puts the way out. The glass alone is nearly invisible
against `Brand.canvas`, which is most of the point of that ground, so the
circle carries a little white over it.

### The sky is the window's ground, and it is flat

The scene is not a picture in a frame: it fills one pane of a window whose
other panes are `Brand.canvas`, so a sky a shade off that ground reads as a
seam down the middle rather than as depth. `GalaxyRenderer.sky` is that colour
in the shader's units, and `verify_galaxy.sh` reads a corner pixel of an
offscreen render and asserts the bytes, so the two cannot come apart quietly.

**The vignette is gone rather than reduced**, and it took three goes to accept
that. It was 0.42, then 0.10, then 0.05, and every one of them was a gradient
against a sidebar that is one flat colour: the seam simply moved to wherever
the fade had got to by the divider. A sky that *is* the ground has nothing to
be darker than.

That change also broke the pixel check, which is worth knowing before touching
either: stars are blended **additively** onto the sky, so a yellow star over a
blue-black ground is a yellow-plus-blue pixel, and its hue drifts towards the
sky as the sky gets lighter. Moving from RGB(2,4,9) to RGB(10,15,29) dropped
the measured people count from 63 to 9 with nothing about the stars changed.
`tools/pngstats.py` subtracts a corner pixel before classifying.

### A window colour is four things, not one

`Brand.canvas` is the app's ground and `w.backgroundColor` carries it to every
pane that draws none of its own. Three kinds of surface do not inherit it, and
only one of them was a bug:

- **The titlebar.** A window without `titlebarAppearsTransparent` draws the
  system's material there whatever its background is, so the release notes
  opened as a navy page under a grey RGB(33,34,38) strip. Setting it changes no
  layout without `fullSizeContentView`: the content still starts below the
  titlebar and only its colour comes from the window. Every window in this app
  sets it now.
- **Cards and fields, on purpose.** A text field is `.textBackgroundColor` and
  the player card and the speaker-review card are `.controlBackgroundColor`,
  because a control that is the same colour as the page it sits on is not a
  control. Leave those alone.
- **Floating panels, also on purpose.** The recording indicator and the
  dictation pill are `NSVisualEffectView`s over whatever app is in front, not
  over Listen. A solid Listen-coloured box floating over somebody's editor is a
  worse thing than a slightly different dark.

### Collapsing the sidebar puts the window's own controls on the legend

The window is `fullSizeContentView`, so the picture has always run up under the
title bar. What kept the legend clear of it was the sidebar: everything before
`.sidebarTrackingSeparator` (the traffic lights, the masthead, the gear, the
collapse control) is drawn over the sidebar's own width. Collapse it and all of
that lands on this pane's top-left corner, on top of the legend, which is what
the reader saw.

`updateTitlebarInset` asks the question the pane can actually answer: not "is
the sidebar collapsed", which is the split view's business, but **does this pane
reach the window's left edge**, which is where those controls are. The title
bar's height is measured rather than remembered, as whatever falls outside
`window.contentLayoutRect`, so it follows a toolbar style change. The same strip
is reserved for the label pass while it applies, so no star's title is written
under the traffic lights either, and an open sidebar costs the labels nothing.

**Where a view landed is invisible to a `texts` dump**, which is why this could
ship broken under a suite that already read every string on the pane. `axprobe
frame` was added for it: it prints the screen rect of the first element matching
a needle, and section 11 of `verify_galaxy.sh` presses the collapse control and
asserts the legend drops by more than half a title bar and comes back.

### Every hue belongs to a shell, and everything else is grey

Four shells, four colours, and the two rules that took three passes to find.

**No two shells may share a hue.** People were blue and notes were amber; the
owner asked for people to be the warm one, and swapping them put notes into a
cyan a few percent from the recordings teal. At star size those are one colour,
so the two most numerous shells said nothing to each other. Notes are a true
blue now and chats moved to magenta to keep clear of it.

**Nothing decorative may wear a shell's colour.** The links were a blue within
a few percent of notes, and the ornamental background stars were another. A sky
full of decoration read as a sky full of notes, and `tools/pngstats.py` could
not tell them apart either: it counted 907 "note" pixels on a library with four
notes in it. Links and background stars are neutral grey now.

That pixel count is what found both. A colour bug is invisible to every
assertion that counts nodes, and on a dark scene at star size it is easy to
miss by eye as well.

**The inner shells are drawn larger.** One radius for every star made people
nearly invisible: the fewest members, closest to the centre's glow, and the
most nameable thing in the library. 0.28 down to 0.19 going out, and selection
and hover still win so the star under the pointer is always the largest thing
near it.

### The scene follows the pointer, and one axis shipped the other way

Drag right and the galaxy comes with you; drag up and it comes up. That is what
every 3D viewer does and what the reference does, and it means the *camera*
moves the opposite way on both axes, so both terms in `GalaxyCamera.orbit` are
subtracted.

The horizontal was added. Dragging right sent the scene left while dragging up
brought it up, and **one axis disagreeing with the other reads as the picture
being broken rather than as a minus sign** — which is how it was reported. It
survived every check in the suite, because a sign is invisible to a count and
to a screenshot alike.

Two things to know before changing it. The reference is Three.js
`OrbitControls`, whose `clientY` runs downwards where AppKit's runs up, so its
two subtractions become one subtraction and one negation-then-subtraction here;
the derivation is written out above `orbit`. And **a drag is a rotation about
the target, so the far side of the galaxy moves the opposite way from the near
side** — a claim about "the scene" is a claim about the near face, and a check
that picks a marker beyond the target measures the right thing backwards. That
cost a wrong red the first time this was tested.

The rate is per point of viewport height rather than a fixed constant, at
Three's `rotateSpeed` of 0.45, so a drag across the pane is the same turn
whatever size the window is.

### Selecting moves the pivot, and nothing moved it back

Clicking a star sets `camera.target` to it, which is what makes the next drag
orbit around the thing being inspected rather than around the middle of the
library. Clearing the selection left it there. So after one click and one
cross, the galaxy turned about a recording out on the fourth shell: the bright
centre swung around the frame, and Reset view was the only way home. Reported
as "the star with my name in it is not the centre of the rotation", which is
exactly what it was.

`select(nil)` puts the target back at the origin now, and keeps the distance:
how far in somebody has zoomed is theirs, and only what the picture turns about
is being corrected. `tools/galaxy_geometry.swift` asserts both halves, because
this is invisible to every count and to a still image alike.

The other thing that moved the pivot was **shift-drag panning**, which was
wired while the list of decisions below claimed "No panning". A panned target
leaves the galaxy off screen with no cue which way to drag back, the reference
disables it, and it is gone: every drag orbits.

### The near stop is derived from the shells, and only a picture bounds it

`minimumDistance` was 2.5, which is **inside** the people shell at 5: a scroll
took the camera within the innermost sphere looking outwards, the centre filled
most of the frame, stars ran off every edge, and nothing on screen said which
way was out. It is the innermost radius plus the centre's own drawn radius plus
a margin now, 5 + 1.2 + 1.8, computed from `Galaxy.shellRadius` so it follows
the shells if those move.

**The geometry checks bound the camera; only a picture bounds the glow.** The
centre is drawn at radius 1.2, and `tools/galaxy_geometry.swift` asserts what
that subtends, but what fills the frame is the bloom around it, which is a
fragment shader and not a number. `listen galaxy --image out.png --closest`
renders at the stop and `verify_galaxy.sh` counts the lit pixels.

Shrinking the range changed what a scroll is worth, which is worth knowing
before touching either. The range went from `ln(36)` to `ln(11.25)` log units,
so 0.009 per point stopped being two thirds of a swipe and became almost all of
it: the rate is 0.007. A check that measures a swipe has to start from the far
stop, too, or the near one clamps the result and a correct rate reads as slow.

### Framing a selection is framing its neighbourhood

A fixed 14 units from the selected star was the obvious version and it put the
camera *inside* a sphere of radius 17 looking outwards: the star filled the
middle of the screen and the things it links to, which is the entire reason
anybody clicked it, were off the edges. The neighbours decide the distance now,
with a floor so a star that links to nothing is not pressed against the lens.
The rest of the library dims rather than going out; at the first dimming value
it went black at that distance, and a recording with two links looked like a
star alone in space.

### A title is the star, and testing its rect is why dragging still works

The labels sit beside the dot they name, and `GalaxyLabel` refuses hit testing
so that a drag beginning on one still orbits the scene. The cost was that a
click on a title fell through to the Metal view and picked whatever the ray
found behind it, which is usually nothing: the word was inert, and it is the
larger target and the one a reader aims at.

`star(at:)` tests the laid-out label rects before it casts the ray. That keeps
every gesture in the Metal view, so the drag behaviour is untouched, and makes
the word as clickable as the dot. The rects are rebuilt with the labels, so
they cannot describe a frame that has moved on.

### The globe carries the page, and the sidebar is what brings you back

Every page in this window ends in the same pair, an ellipsis and a cross. The
globe goes between them and opens the galaxy on *that page's* star, so a
person's page becomes that person with their links lit rather than the whole
library and a hunt. On the home page it takes the ellipsis's slot instead,
because there that menu holds one row saying "No recording selected".

**The way back needed no code**, and that is worth knowing before somebody adds
some. The galaxy leaves the sidebar's selection alone, and the library branch
of `enter` restores whichever pane that selection implies, so the cross lands
back on the page it came from by itself. Picking a different star inside the
galaxy does not change that, which is right: the cross means "leave this", not
"open the thing I last looked at".

### A script cannot click this app's sidebar

Every row in that list is a `HoverRow`, a plain `NSView` with a target and an
action, so it reaches neither `axprobe press` nor `selectrow`, and the status
menu's Recent rows only cover the newest few. `LISTEN_PANEL=page` opens the
first recording's page, which is the only way `verify_galaxy.sh` gets one on
screen to check what its toolbar carries.

### A search narrows the picture to its matches and their links

The field that narrows the list beside it narrows this too. Matches are drawn
lit and named; everything else in the sphere goes to context, and anything with
no link to a match is dropped entirely. **Not the matches alone**: two stars in
an empty sphere with no lines answers "is Herman in here" and nothing else,
where the neighbours answer "and what about him".

A selection outranks a search, because clicking a star while a search is up is
the narrower question and two sets of lit stars would answer neither.

**Both halves of this shipped with nothing joining them.** `Sidebar` had
`onSearchChanged` and `GalaxyPane` had `setSearch`, and the window never
subscribed one to the other: the pane's entry point had no caller anywhere in
the repo, and typing a name narrowed the list to two rows beside a picture with
every star still in it. Reported as "searching still doesn't filter the galaxy
nodes", which is what it was. Two things it needs beyond the subscription: the
handler is guarded on the mode *before* `galaxyPane` is touched, because the
pane is lazy and reaching for it from the library builds a Metal view and reads
the library for a mode nobody has opened; and `enter(.galaxy)` applies
`sidebar.searchQuery` on the way in, because the field keeps its word across a
mode change and `onSearchChanged` only fires on a change.

A search nothing answers says so. With the neighbours gone too there is nothing
left but the centre, and a galaxy that goes blank reads as broken rather than
as empty: the status line names the word that emptied it, which is the same
rule as the cap being disclosed.

### A role is not an accessibility element, and the whole sentence was inert

The Metal view sets a role, a role description and a label saying what the
picture is and where the same things can be reached as a list. None of it was
in the tree. `NSView.isAccessibilityElement` is false by default, so a view
that sets a role and a label and nothing else is still not an element, and
`axprobe texts` could not find a word of it.

That is worth more than the VoiceOver fix, because **the label is the only
handle a script has on what the GPU drew**: the stars are pixels, so the count
in that sentence is the one measurable thing about a filter. Section 12 of
`verify_galaxy.sh` reads it before and after a search, 19 stars to 3 and back,
which is an assertion no screenshot and no other element in the tree can make.

### A selection names itself and its links, and nothing else

The label budget takes turns between the four shells only while nothing is
selected. With a star picked, everything else in the scene is dimmed to
context, so labelling it puts twenty unrelated titles over a picture whose
whole point at that moment is one thing and what it connects to. Selected,
hovered and neighbours; the centre keeps its label as the one fixed reference
in the frame.

### The label pass returns when nothing it depends on has moved

Rebuilding two dozen `NSTextField`s is the one part of this pane that is not on
the GPU, and `invalidate` reaches the label pass from the camera, the
selection, a layout and a reload alike, most of which change nothing a label
depends on. So it compares its inputs first.

**Which inputs is where the bug was.** Keyed on the camera, the time, the
selection and the view's size, it skipped the corrective pass after the
inspector card resized itself: `select` fills the card and asks for a redraw in
the same turn, so the pass reads the card's frame before Auto Layout has
resized it, and the layout that follows presents an identical key. With the
motion paused, under Reduce Motion or in Low Power Mode nothing ever ran it
again, and the titles stayed underneath. The four rects the pass keeps clear of
are part of the key now, and `setBottomInset` asks for the redraw it never
asked for.

A review also argued that the pass could sustain a layout loop, because adding
an autoresizing subview to an Auto-Layout superview marks it as needing layout,
which reaches `viewDidLayout` and comes back. **That was not observed**: the
prototype's smoke test measured exactly 0 frames over half a second with the
motion paused, five consecutive runs, which a live loop would not allow. The
guard closes it either way, and the saving above is the reason it is there.

### Attraction is towards the average neighbour, never the sum of them

Summing the edge force pulls a star with forty edges forty times as hard as one
with a single edge, and every library has a star like that: you are in all of
your own recordings. Measured on a synthetic library where three people spoke
in all forty-eight meetings, the summed version dragged the whole picture into
one hemisphere and left the other half of every shell empty. It was invisible
in every count-based check, because the counts were all correct and the stars
were all exactly on their shells; `listen galaxy --image` is what showed it.

Dividing each star's accumulated pull by its degree fixes it. The real library
was less obviously wrong and still wrong: `Me` speaks in 76 of 76 recordings.

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
- **No status line restating the picture.** It said "159 of your library, on
  four shells" on every galaxy, which is the shells saying it twice. It speaks
  only for what a reader cannot see: a library still being read, an empty one,
  and stars the cap dropped.
- **No composer.** Ask is on every other screen in this window and not on
  this one: the field would be the only thing here that is not the picture, it
  competes with the inspector card for the same corner, and a question about a
  star has a page of its own to be asked from. This reverses the first version,
  which argued that "Ask about your library" over a picture of the library was
  exactly right; what it actually produced was a bar over a scene, and a
  bottom inset to plumb so the controls could dodge it.
- **No filter that outlives the window.** Striking a shell out of the legend is
  a lens over the snapshot, not a narrower read of the library, and it reaches
  no preference: a filter somebody finds still applied a week later is one they
  have no memory of setting.
- **No panning.** The reference disables it too, and this was a claim before it
  was true: shift-drag panned for several builds after the sentence was written. With the target pinned to the
  centre the camera is two angles and a distance, which is what makes Reset a
  guarantee rather than a best effort; a panned target can leave the galaxy off
  screen with no cue about which way to drag back.
- **No keyboard navigation of the stars, and no accessible element per star.**
  They are pixels the GPU drew inside one `MTKView`, not views, so there is
  nothing to focus and nothing to read. Building an accessible element per star
  would be building a second list of the library beside the one already in the
  sidebar, which is fully navigable and opens the same pages. The Metal view
  says exactly that to VoiceOver, with the counts, rather than presenting
  itself as an empty image.
- **No second read of the library.** The pane calls `Galaxy.build` on a
  background queue and coalesces requests: the window reloads on activation, on
  a recording arriving and on the queue advancing, and three passes for one
  visible change is three passes nobody asked for.
