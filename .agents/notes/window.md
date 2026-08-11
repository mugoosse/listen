# The library window: sidebar, detail pane, playback

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

Listen's own window behaviour. Read this before touching `LibraryWindow`, `Sidebar`, `DetailView`, `NotePane`, `WaveformView` or the settings mode.

## The recording in progress is not in the library

It is in `staging/`, and `Recording.all()` lists `recordings/`, so for the whole
length of a meeting the sidebar knew nothing about the meeting. Pressing Record
changed the toolbar button and nothing else: no row, no selection, nothing to
click. A list that looks identical before and after you press Record is
indistinguishable from a Record button that does not work, which is the one
doubt this app cannot afford.

`SidebarViewController.reload()` therefore prepends `Capture.shared.current`,
`LibraryWindow.recordingChanged()` rebuilds the list on both edges of capture
and selects the new row **once**, and the per-second tick that advances the
toolbar clock also re-renders that one row. One row and not `reloadData()`: a
full reload every second cancels a drag, fights the scroller and rebuilds every
cell in the library to advance one number.

Three consequences, all of which were bugs first:

1. **`Capture.stop()` re-reads `metadata.json` from disk.** It used to save the
   copy taken at `start()`, which was correct only while nothing could edit a
   recording that was still running. Now the row is selectable and the title is
   editable, so renaming a meeting while it records and then stopping wrote the
   hour-old copy back over it and the name was silently gone.
2. **The sidebar reads the live recording from disk too**, for the same reason:
   `Capture.current` holds the metadata as it was an hour ago.
3. **No player and no waveform while it records.** Both tracks exist and are
   growing, so a mixdown built now is of half a meeting, and `Waveform` would
   cache that half against a key that is only its format version. The pane says
   what is happening instead.

`SidebarViewController.reload()` calls `loadViewIfNeeded()` first. The list is
now rebuilt whenever capture changes, and capture can change before the window
has ever been shown, because `rebuildMenu()` runs at launch. `table` is created
in `loadView`, so without it the first reload is a nil unwrap.

### One elapsed clock per screen, and the row is the one that always counts

Once the recording in progress had a row, the library counted the same seconds in
three places at once: the sidebar's Stop row, that row, and a toolbar button
sitting over the meeting's own title. Three copies of one number is not three
times the reassurance, it is a screen where nothing looks like the source.

The row keeps its clock, because it is the one place that is always on screen and
is about that recording rather than about the app. The toolbar's stop control
appears **only while the recording in progress is the one selected**, and takes
the place of People and Actions rather than the leading edge of the content: a
running recording has no transcript to export and no speakers to open, so on that
one screen stopping it is the only verb there is.

The toolbar's control said "Stop 0:58" for a while, which was the third copy
coming back by another door: the row two hundred points to its left was already
counting the same seconds. `RecordButton.State.stop` carries nothing now and the
button says "Stop". Two things went with the clock, and both are the point of
recording this rather than the label:

- The per-second timer in `recordingChanged` no longer calls `updateRecordFAB`.
  It exists for `sidebar.tickLive()`, which is the row, and a button with no
  digits in it has nothing to tick.
- `syncRecordItem` stopped sizing the item from `fittingSize` with a floor of
  132. The floor was free while the shortest label was "Stop 0:58"; around the
  word "Stop" it drew a 132 point capsule with the icon and the word packed
  against the left edge, because `RecordButton.layout` measures from the leading
  inset and never centres. The floor was there because `fittingSize` is zero
  before the first layout pass and an unsized custom-view item is drawn as
  nothing at all. `intrinsicContentSize` needs no layout pass, so the item is
  sized from that and the number is gone.

`monospacedDigitSystemFont` went too. It was there so the clock could not change
width as it counted, and neither label has a digit in it now.

Then the `p` of "Stop" came out clipped, which is `appkit.md`'s
"`intrinsicContentSize` is four points narrower than the text": the label's
frame is set by hand here, and it was being set to the narrower of the two
measurements. It is the same four points on every string, and only a glyph with
something on its right edge shows it.

The sidebar's row stops being a control at all. It used to become a red Stop row
with a clock in it; it now keeps the words "New Recording" and greys, because the
only thing true of it during a meeting that is not said anywhere else is that
there is no second recording to start. A row that swaps its verb, its icon and
its colour is a row you have to read before you can trust what pressing it does,
and there were already two stop controls on screen. `SidebarRow.isEnabled` dims
the whole row and stops the hover and the action; the tooltip says where stopping
lives, because a greyed control with no reason beside it is the shape people read
as broken.

Red is on the state word alone, not on the line. `18:04 · 0:09 · recording` puts
the same clock and time every other row prints in the same colour every other row
prints them in, and colours the one word that is not. Colouring the line said the
clock was the alarming part rather than what it was reporting. `configure` builds
an attributed string for this, and each run has to carry the font: the monospaced
digits set on the field are not inherited, and without them the clock changes
width as it counts.

Two consequences:

1. **The toolbar is rebuilt on selection changes, but only during capture.**
   Which items belong now depends on what is selected. Outside a meeting that
   question has one answer, and rebuilding anyway is five items removed and
   re-inserted on every click in the list.
2. **`recordingChanged()` rebuilds last.** It selects the recording that just
   started, and `isShowingLive` is asked of the selection, so rebuilding before
   that leaves the stop control out for the length of the meeting.

Settings and People keep the stop control unconditionally while capture runs, and
so does the menu bar item. Those are now the only two ways to stop a meeting you
are not looking at, which is the trade this makes: one control on the screen that
is about that recording, rather than one on every screen.

## A sidebar reload is not somebody choosing a recording

`SidebarViewController.reload()` rebuilds the list and puts the selection back on
the same recording. Both halves post
`NSTableViewSelectionDidChangeNotification`: `reloadData` drops the selection and
`selectRowIndexes` restores it. Reported as a selection change, that runs
`onSelect`, which is `DetailView.show`, which **stops playback, puts the playhead
back to zero and rebuilds every turn.**

So every reload was blanking the pane and rebuilding it, and renaming a recording
or correcting a sentence while listening silenced the recording being corrected.
Measured: paused at 00:03, rename, 00:00. That is exactly what `applyEdit`'s
"targeted reload, not `show`" exists to prevent, and it was undone by the
`onChanged?()` on the line after it.

`reloading` suppresses the callback while the list is being rebuilt. Landing
somewhere new is still reported, at the end of `reload`, because then it is true,
and the deliberate cases already call `onSelect` themselves: `select(_:)` does it
when the id differs, and `LibraryWindow.reload()` re-shows the selected recording
explicitly so a transcript that has just finished appears without anyone clicking
away and back.

`DetailView.onChanged` reloads the list only, and no longer the pane that just
wrote the change: the pane is already showing what it wrote, either a title it
has in hand or a sentence it re-rendered in place.

Measured after: paused at 00:03, rename, still 00:03, with the row in the list
carrying the new title.

## The floating panel is sized from its strings, and one of them changes

`RecordingIndicator.layout` measures every frame from the text it is drawing,
which is the right call for a label that carries an app name. The clock is the
exception: it is laid out once by `show`, when it reads "0:00", and then
`setElapsed` rewrites it twice a second without anyone re-measuring. From ten
minutes in, the label is a character too narrow and the panel spends the rest of
the meeting reading "33:1". A cut-off clock is worse than no clock, because it
still looks like a time.

`setElapsed` therefore re-lays the panel out when the string's **length**
changes, which for `monospacedDigitSystemFont` is exactly when its width does,
and re-positions it because the panel is pinned by a corner rather than by its
origin. Once per digit, not twice a second.

It took ten minutes of a real meeting to see, which is the actual bug:
`LISTEN_PANEL=recording` could only ever show "0:00", because a preview launch is
recording nothing. `LISTEN_PANEL=recording:1994` now seeds the clock, and
`RecordingIndicator.previewElapsed` is what the tick reads instead of `Capture`.
Same argument as the affordance itself: a state that cannot be put on screen on
demand is a state nobody checks.

**A preview launch also stops before it touches the library.** It used to adopt
staged recordings, sweep staging and resume the queue like any other launch, so
looking at a panel beside the running app meant two processes transcribing the
same audio. `MainMenu.install()` moved above the check so a preview still has a
Cmd-Q; everything after it is skipped.

## The panel is dragged by its whole face, and parked by a corner rather than a point

The panel can be moved, and the hard half was not the dragging.

**A corner, not an origin.** `PanelPlacement` stores which two edges of the
screen's `visibleFrame` the panel is measured from and how far in it sits, and
the whole reason is the note above: this panel resizes as its strings change, so
it has to know which of its own corners is nailed down. Parked against the right
edge it has to grow leftwards, parked against the left edge it has to grow
rightwards, and an origin cannot say which. Measured on a 1512x982 screen, panel
252 points wide at "10:00" and 263 at "1:00:00":

| stored | clock | frame |
|---|---|---|
| `right top 620 252` | 10:00 | x 640, right edge 892 |
| `right top 620 252` | 1:00:00 | x 629, right edge 892 |
| `left top 100 100` | 10:00 | x 100 |
| `left top 100 100` | 1:00:00 | x 100 |

The corner is chosen for you, from whichever corner of the screen the panel was
nearest when it was let go. Nobody is asked which edge they meant.

The same shape is what makes the placement portable between screens. The panel
appears on whichever screen has the mouse, which is unchanged and is exactly why
an origin would not do: a point read off a 27-inch display is off the bottom of a
laptop's. `origin(for:in:)` clamps as well, so `left top 5000 5000` lands at
1260,893 rather than nowhere, and there is deliberately no reset command. A
placement that cannot put the panel off screen does not need one, and
`defaults delete com.mgo.listen recordingPanelPlacement` is the way back to the
corner it starts in. Nothing is stored until somebody drags, so that corner can
change later without stranding anybody.

**`isMovableByWindowBackground` is the one-liner and it is not enough.** The flag
only starts a drag when the click reaches the window, and the labels are
`NSTextField`s, which are controls and eat it. Dragging worked over the padding
and died over the word "Recording", which reads as a broken panel rather than as
a rule anybody could learn. `DragBackground.hitTest` answers `self` for
everything that is not inside an `NSButton`, so the labels, the dot and both
strips are grab area and the buttons keep their own clicks. `mouseDown` then
hands off to `performDrag`, because the system's drag loop is the one that knows
about display edges and the spaces this panel joins all of.

**Telling a drag from our own placing.** `NSWindow.didMoveNotification` is where
the placement is written, and it fires for everything: the user's drag, the
`setFrameOrigin` in `position`, and the `setContentSize` in `layout`, which moves
the origin because it keeps the top left corner. Two guards, because they cover
each other's hole: `placing` is up for the whole of `replace`, which catches a
notification delivered inside the relayout, and `placedOrigin` catches one
delivered after it, when the flag has already gone back down. `settle` runs when
a drag ends and only clamps a panel dropped over an edge; it stores nothing, so
there is one writer.

Measured, over `LISTEN_PANEL=recording:600` on a copy of the app with its own
bundle identifier, so none of this touched the real preferences:

- nothing stored puts it at 1244,45: 16 in from the right and 12 below a 33-point
  menu bar, which is where it has always been
- a drag from 40,853 to 640,285 stored `right top 620 252`, and the next launch
  opened at 640,285
- a click on the panel's face neither moved it nor rewrote the preference
- the dismiss button still dismisses, so `hitTest` is routing controls correctly

Those drags and clicks were synthesised, and that is worth naming: they exercise
exactly the routing `hitTest` governs, which is why they are here, but a
synthetic drag agreeing is not a real drag agreeing. The panel's neighbours are
also worth knowing about. `DictationHUD` and `QuitConfirm` both place themselves
away from the top right *because this panel is there*, and now it need not be.
Their avoidance is one-sided on purpose: a pill that moved itself out from under
a dragged panel would be a second thing on screen going somewhere nobody asked.

## Setting `editing = false` is not what closes the person editor

`PersonPane.render` is, and for a long time the only thing that called it after
a save was the roster re-selecting the same person. A **rename** is exactly the
case where that cannot happen: `PeopleNav.reload` and the window both re-select
by label, and the label they are holding has just stopped existing. Nothing
re-selected, nothing re-rendered, and the edit fields sat there with Cancel and
Save still under them. Rename looked like it had done nothing, with the
transcripts already rewritten behind it.

Two halves to the fix, and both are needed:

1. **`saveEdits` calls `render()` itself.** The pane closes its own editor
   rather than depending on somebody else re-showing it.
2. **`onLandOn(label)` replaces `onMerged`.** A rename, a merge and an unnaming
   all leave the roster selecting a name that is gone, and all three now say
   where the person went. `PeopleNav.select` returns `false` when the label is
   not in the roster, so the window can show the empty page rather than leaving
   the last one frozen. It used to return silently, which is the same class of
   failure one layer down.

**A rename that rewrites nothing is refused rather than followed.** Landing on
a name nobody has empties the pane, and from the outside that reads as the app
having deselected the person, not as a rename that failed. So `saveEdits` stops
and says so when `People.rename` changes no recordings and there were
recordings to change. Found by driving the real UI against a hand-written
`transcript.json` that was missing `wordLevel`: `StoredTranscript` would not
decode, `hasTranscript` was true, the rename silently rewrote nothing, and the
person vanished from the page. Both the CLI and the window said nothing.

## A recording nobody named is called "Untitled"

The default was "Recording, 5 Aug 2026 at 14:31", which repeats the day heading
and the time already printed on the same row, and makes an unnamed recording
look like a named one. The placeholder is stored rather than left blank so the
CLI, the MCP server and an export all have something to print, and
`Recording.isUntitled` is the one place that knows the string.

The detail pane shows it as an actual `placeholderString` with an empty field
behind it, so clicking the title gives you somewhere to type rather than a word
to delete first, and clearing the field un-names the recording rather than
being refused. `exportName` puts the date back for a filename, because a folder
of `Untitled.md`, `Untitled 2.md` is a folder nobody can read.

## Collection navigation is in the sidebar, not the toolbar

A three-way segmented control above the search field: Recordings, People, Notes.
People used to be a toolbar button and is not one any more.

**The rule it encodes: a toolbar holds verbs on the selected recording.** Export
this, transcribe this again, delete this. People was never a verb on a
recording, it is a peer collection of the whole library, and once a note can
name four recordings so are notes. A note referencing four meetings has no home
in a recording-centric sidebar at all, which is the sharp version: without this
the app can create something it cannot show.

Five things it has to get right:

1. **Above the search field, not below.** Search scopes to the active segment,
   so the scope selector comes first, and the placeholder changes with it
   ("Search recordings", "Search people", "Search notes"). Otherwise the first
   search in People returns people as a surprise rather than an expectation.
2. **Settings is not a fourth segment.** The segments are which part of the
   library you are looking at; settings is configuring the app. It keeps a gear
   of its own, which is in the title bar beside the collapse control.
3. **Each list carries its own copy of the control**, because the sidebar swaps
   its whole view controller through `PaneHost`. Same builder, same constraints,
   same position, so it does not appear to move. The cost is that they go out of
   sync: clicking Notes on the recordings list leaves *that* control reading
   Notes, so coming back showed the recording list with the Notes segment lit.
   Measured that way round. `enter()` sets all three, not just the one on
   screen.
4. **Do not touch `minimumThickness`, `maximumThickness` or the holding
   priorities on a segment change.** One `autosaveName` owns the divider, and
   moving the limits makes the split view redistribute and rewrite the saved
   width. `CLAUDE.md` already records this for the settings mode; a segmented
   control changes mode far more often than Settings does.
5. **Every list needs the way to Settings, not just the recordings one.** The
   recording list was the only one with a bottom row, because People was entered
   from the toolbar and left by a back row. Peers behind one control, a gear in
   one of them means being in People or Notes is being somewhere with no visible
   way to Settings. Found by looking for it and it not being there. It was one
   builder making the row, the hairline above it and its constraints for all
   three lists; it is one toolbar item in all three modes now, and the note
   below on the title bar is why.
6. **People and Notes no longer lock the sidebar open.** That lock existed
   because the roster was the only way out of the person page. The segmented
   control is now the way in and out of everything, so the lock was about
   navigation rather than about People, and the sidebar toggle is back in the
   toolbar in those modes. The masthead is in all three too: switching is one
   click now, and a title bar that empties as you move between segments reads as
   three different apps.

A note's sources are `SourceChip`s, and they took three goes. An `.inline`
button draws a flat grey capsule that reads as a tag, so nothing said the
meeting a note is about was also the way to it: zero signals. An accent-filled
capsule with a chevron said it far too loudly, and on a note whose body is one
sentence the loudest thing on the page was the navigation. What is there now is
a link: accent text, a chevron, a pointing hand, no fill.

The label in front of them went with the capsule. "Open a recording:" spent a
third of the row on a sentence introducing four things that already look like
links.

The header lost a line too. It carried who wrote it, when, and, on the user's
own note, a sentence saying it is edited on the recording, every time it was
shown for ever. That sentence is a thing somebody needs once, so it is the text
view's tooltip, and what is left is the same two facts the sidebar row already
prints in the same order.

A note's sources are links in a sentence, not a row of buttons. Buttons with a
trailing chevron each read as one step of a path, so four of them are a
breadcrumb trail claiming a hierarchy that does not exist: these are four peers.
`LinkLine` is an `NSTextView` that reports an intrinsic height, so a
comma-separated line of links wraps, underlines on hover and takes the pointing
hand for free. The `listen-recording:` scheme is made up and read back by the
delegate that owns the view, so an id in a note's provenance can never reach
`NSWorkspace`.

**An `NSTextView` reports no intrinsic size**, which is fine inside a scroll
view and wrong everywhere else: pinned into a stack of constraints with nothing
saying how tall it is, it took the whole pane and pushed the note body off the
bottom of the window. The symptom is a note that renders its header and nothing
else, which reads as an empty note.

The same line appears under a note shown beside a recording, as "Also about",
and it is links there too. `LibraryWindow.open(recording:note:)` is the one
entry point both use, and **they land on different tabs**.

From the Notes collection it lands on the Notes tab with that note beside the
recording: the whole page has changed, and a synthesis of four meetings has to
be walkable through its sources without losing your place in it.

From "Also about" it lands on the **transcript**. The note being read is about
that meeting too, so staying on the Notes tab put the same words under a
different title, and a page that does not visibly change is a click that did not
appear to work. The rule generalises: land where the change is visible.

**A leading heading that repeats the note's title is dropped when rendering.**
An agent asked for "Decisions" writes `# Decisions` as the first line, which is
right in a markdown file somebody may open in an editor and reads as a mistake
on a pane whose own title is two lines above it. The file keeps it.

**Every one of the user's notes is titled "Your notes"**, so the library list
was a column of identical rows told apart by a truncated second line. Those rows
lead with the meeting and put "Your notes" where the kind goes; an agent's note
is the other way round, because its title is the one thing that is its own.

Clicking one lands on the **Notes tab** of that recording, with the same note
selected. Landing on its transcript would be answering a
question nobody asked, and a synthesis of four meetings has to be walkable
through its sources without losing your place in it.

`NotePane` is read-only for every note, including the user's own, and that is a
choice rather than an omission. Their note is edited on the recording it belongs
to, where the audio and the transcript are, and two editors for one file would
be two writers of the thing this app is most careful about. The sources are
buttons, so the way to edit it is one click and the click also goes to the
meeting.

### Reading the popup's selection after rebuilding its menu returns the old one

`pickNote` called `saveYours()` before reading `sender.selectedItem`, and
`saveYours` calls `rebuildNotePicker`, which re-selects the note that is on
screen. So picking a different note in the switcher read back the note you were
leaving, and the pane redrew what it was already showing. The symptom is a
control that appears to be dead, which is the hardest kind to attribute.

The choice is read first, before anything that could touch the menu. The wider
rule: an action handler that rebuilds its own control has to take what it needs
off the sender on the first line.

### A day heading that pins to the top is not a row that has vanished

Reported as "the first recording of the day disappeared": the sidebar showed
"Today" with nothing beneath it and "Yesterday" immediately after. It was not a
bug. `NSTableView` floats group rows, so the heading of the group you are in
stays pinned while its rows scroll away underneath, and landing at the one
offset where Today's only recording had just gone past the top leaves exactly
that picture.

Three wrong theories went by before the measurement that settled it: the table
reported 58 rows before and after, and asking through accessibility returned the
right title for the row that was not on screen. Data right, drawing right,
heading in front of it.

**The fix is not `floatsGroupRows = false`.** That was tried, and it removes the
sticky heading and its separator, which are the thing that tells you which day
you are looking at halfway down a long library. Turning off a feature to
suppress a symptom is how a report of "this looks wrong" becomes a regression
nobody asked for. What put the list at that offset is `select`'s own
`scrollRowToVisible`, which is correct: arriving from a note has to bring the
recording into view.

### A recording with no call shows Listen's own icon

`appBundleID` is nil for a recording started from the sidebar in a quiet room,
so its icon column was empty while every other row had one. `AppNames.own` fills
it, which is the true answer rather than a blank: that meeting was recorded by
this app and by nothing else. It also keeps one left edge down the list instead
of one that changes as you scroll.

### The document toggle sits above the player, not below it

The player belongs to the transcript. A transcript is a thing you read while
listening; a note is a thing you write. Under the player the toggle read as a
control on the recording rather than a choice of document, and switching to
Notes left 58 points of transport on screen with nothing to transport.

So `modeBar` is between the chips and `playerCard`, and the player is collapsed
in notes mode through the same two-constraint pattern the chips row uses. It is
also collapsed when there is no audio, which closes a gap that had been there
since before any of this and that nobody had noticed.

Switching to Notes stops playback, which is the rule `enter(.settings)` already
follows: a transport nobody can see is a transport nobody can pause. The cost is
that you cannot listen back while typing, which is a real thing somebody might
want and is worth revisiting if it comes up.

### A convenience initialiser that shadows its superclass's calls itself

`SourceChip` is an `NSButton` subclass, and its first version was:

```swift
convenience init(title: String, target: AnyObject, action: Selector) {
    self.init(title: title, target: target, action: action)   // itself
```

`NSButton` already has `init(title:target:action:)`, so `self.init` resolves to
the subclass's own initialiser and not the superclass's. It compiles clean, and
crashes the first time a note is selected: `EXC_BAD_ACCESS`, "thread stack size
exceeded due to excessive recursion", **74,609 frames** of
`SourceChip.__allocating_init(title:target:action:)`.

Any argument label that is not `title` sends it to `NSButton`, so the parameter
is `recording:`. The general rule: a `convenience init` on a subclass must not
have the same signature as an initialiser it means to call.

Two things made this cost more than it should have. It only fires on a code path
a click reaches, so a build and a launch both look fine, and every screenshot
taken before that click is evidence of nothing. And the fix is one word, which
is the shape of bug worth writing down rather than remembering.

## The user's name is a preference, and nothing said where to set it

`Settings.userName` has existed since the label design was settled: the
transcripts keep saying `Me` and `SpeakerName.display` resolves it on the way to
the screen, so the name can change without rewriting anything. The person page's
editor already wrote it, and so did `listen me`.

What did not exist was any way to find that out. The Me page's heading said
"Me", the roster said "Me", and nothing anywhere admitted that was a placeholder
or that it could be changed, so the reasonable conclusion from looking at it is
that the app does not know who you are. Settings, General now has the field, and
the Me page carries one dimmed line saying where it is, **only while the name is
unset**.

It was first put inside the `·` list in the person's subtitle, which read badly:
a sentence with a full stop in it, wedged between a job description and a
duration. A hint that is not one of the facts does not belong in the list of
facts.

## The notes pane re-reads on activation, and only redraws when something changed

An agent writes a note while the window is open and nothing on disk announces
it. Coming back to the app is when somebody expects to see it, so `DetailView`
listens for `didBecomeActiveNotification` and re-lists one directory, which is
cheap.

Redrawing is not cheap, though, because rebuilding the text view scrolls it back
to the top. `notesSignature` is every note's slug and `updated` joined up, and an
unchanged signature returns without touching the view. Losing your place in a
note because you switched to another app and back is the same failure
`renderTurns(scrollToTop:)` exists to avoid next door.

The mode itself survives a selection change, the way `DictionaryPane.showing`
does: reading notes down a list of meetings is a mode, not a choice being
repeated. `reloadNotes` puts it back to the transcript when a recording with no
notes arrives, so the mode can never leave anybody on an empty pane.

## Settings is a mode of the library window, not a second window

Anarlog's shape, and the reason is the one the two-window version kept paying:
a settings window is a second toolbar idiom, a second thing to manage, and a
fixed 560 x 500 box that cannot use the space it has. `LibraryWindow` now has a
`Mode`, and both split view items hold a `PaneHost` whose child is swapped:
recording list or section list on the left, transcript or pane on the right.

**A `PaneHost` rather than swapping the split view item's view controller**,
because `NSSplitViewItem.viewController` cannot be changed afterwards and
removing and re-inserting items throws away the divider position that
`splitView.autosaveName` exists to keep. The host's view must draw nothing:
`NSSplitViewItem(sidebarWithViewController:)` puts its material behind whatever
it is given, and a host with a background covers it.

**Do not touch `minimumThickness`, `maximumThickness` or the holding priorities
on a mode change.** One `autosaveName` owns the divider, and moving the limits
makes the split view redistribute and rewrite the saved width, which is the
trap directly above wearing a different hat. Measured across a settings visit:
`defaults read com.mgo.listen "NSSplitView Subview Frames ListenSplit"` returns
the same 280 before and after.

**There are three ways to collapse a sidebar, so blocking one is blocking
none.** The toolbar item is not in the toolbar in settings mode;
`LibrarySplitViewController` overrides `toggleSidebar` and validates View >
Hide Sidebar to disabled, which is where the menu item lands because it targets
nil; and `canCollapse = false` closes the divider drag and the double-click.
`validateMenuItem` is a *conformance* here and not an override: the compiler
says plainly that `NSSplitViewController` does not implement it, so there is no
super to call.

A sidebar collapsed before settings opened is expanded on the way in and
collapsed again on the way out, with `isCollapsed` set directly rather than
through `animator()`: the content is being swapped underneath, and a sidebar
sliding open around a list that has already changed reads as a glitch.

Four more things, each of which was got wrong once:

1. **`show()` always enters library mode.** It is what the Dock icon, Cmd-0 and
   "Open Listen" mean. `showSettings(_ tab: SettingsTab? = nil)` takes nil so
   Cmd-, pressed while already in settings keeps the section you were on.
2. **No window subtitle for the section name.** It draws immediately above the
   pane's own 22 point heading, so the window read "Audio" twice, one line
   apart, which looks like a bug rather than a title.
3. **`selected` returns nil in settings mode**, so the Actions menu says "No
   recording selected" instead of acting on a row nobody can see. That needed
   `NSMenuItemValidation` on `LibraryWindow`, which nothing had: the File menu's
   recording items were permanently enabled and quietly did nothing.
4. **The record control stays in both modes.** Stopping a meeting must never
   mean leaving the screen you are on first, and the button is the only place
   the elapsed clock is written.

`trace()` reports every mode change under `LISTEN_DEBUG=1`, because a mode leaves
nothing behind to inspect. It earned itself immediately: "the window went back
to the library on its own" turned out to be a test script moving the window
under a stationary pointer, which pressed the back button. The stack trace said
`NSControlTrackMouse`, and nothing else would have.

## A settings pane is as wide as the window, up to 620 points

`Pane` was built for a non-resizable 560 point window, so `note`, `separator`,
the skip rows and the MCP box all sized themselves from a `paneWidth` constant.
In a window that resizes, every one of those is a view that stretches to
whatever the display is, and a note running 1400 points across is a line nobody
can track back to its start.

`widthCapped` replaces the constant: a low-priority equality to the stack's
width with a required maximum, which resolves to the smaller of the two. The
stack is leading-aligned and does not stretch what it arranges, so anything
meant to span the pane has to ask.

Two traps around it:

1. **`preferredMaxLayoutWidth` has to be updated before the height is
   measured.** An `NSTextField` computes its height from that and not from the
   width it was given, so a note left at the old width reports the old height
   and loses its last line as the window narrows.
2. **It has to be guarded on change.** Setting it dirties layout, and setting it
   unconditionally from `viewDidLayout` is a layout pass that schedules another
   one forever.

`skipRow` is added to the list *before* `widthCapped` is applied to it, because
the constraint is against the pane's stack and two views with no common ancestor
yet is an exception rather than a layout that sorts itself out.

## The About pane is Speak's, and the app name is one size down

`AboutPane` follows Speak's section for section: identity header, Updates, Setup,
Made by, Built on, then the licence and the source link. The Updates block is the
part that was missing rather than merely differently worded, and the argument for
it is Speak's own: Sparkle answers a check in a window that is then dismissed,
taking the answer with it, and a scheduled check that finds nothing says nothing
at all, so "am I on the latest version" had no answer that survived closing a
dialog. Before this, About offered one `Check for Updates` button and reported
none of what came back.

Three things are Listen's own:

1. **The name is 17pt, not Speak's 22.** The pane draws its own section title at
   22 immediately above, and the previous version of this file records why there
   is no `Listen` heading here: two 22pt words one line apart read as a mistake
   rather than as a title. The 72 point app icon beside it is what makes this an
   identity block instead of a repeated heading, so the header came back and the
   size did not.
2. **`refreshUpdates` does not call `resizeDocument`.** The result line appearing
   does change the pane's height, but `sizeDocument` already runs on every layout
   pass and a text field whose string changed schedules one. The public one also
   scrolls the pane back to its first control, and a scheduled check finishing
   while somebody is reading the credits is not a reason to move the page.
3. **`Updater.onChange` is claimed in `viewWillAppear` and released in
   `viewWillDisappear`.** A check can be started from the menu bar or by the
   scheduler, so following the button alone would leave the pane showing the
   previous answer.

Verified end to end against the real feed by pressing Check Now through
accessibility on a `LISTEN_PANEL=settings:about` launch, which touches nothing in
the library: Sparkle's "You're up to date" window, then the green result line and
`Last checked Today at 15:30` in the pane behind it.

## The transcript opened near the end of the meeting

A freshly selected recording opened on its last few turns with half a paragraph
cut off above them, which reads as a rendering fault rather than as a scroll
position. `renderTurns` now scrolls to the top itself.

Two things are easy to get wrong here, and both were got wrong once:

1. **Use `scrollToVisible`, not the clip view's origin.** `scroll(to:)` has to
   be handed the document height *minus* the viewport height. Hand it anything
   else, the document height for instance, and the transcript goes entirely out
   of sight, leaving an empty pane under the player.
2. **The top is `stack.bounds.maxY`, not zero**, even though
   `TopAlignedClipView` is flipped. Flipping the *clip view* decides where a
   short transcript sits and which way the scrollers run; it changes nothing
   about the stack view's own coordinates, where the first turn is still the
   one with the highest y. The two flags read as if they should agree.
   Measured both ways on an 80 minute recording: y = 0 opens on the last turn,
   y = maxY - 1 on the first.

## A peak envelope of a meeting is a solid block

The scrubber's first version stored the peak amplitude per bucket, which is
what a waveform usually means. At 1400 buckets across an 80 minute meeting a
bucket is three and a half seconds, and the loudest instant in three and a half
seconds of speech is close to the loudest instant in the whole recording, so
every bar came out near full height and the waveform carried no information at
all.

`Waveform.make` stores **mean energy** per bucket instead, which separates
talking from pausing and is the shape somebody scrubbing a meeting is looking
for. `version` exists on the stored envelope precisely so a change like this
recomputes the caches rather than drawing old numbers under new rules.

Normalising it for display is also the opposite of the rule in `Mixdown`, and
deliberately so: playback volume has to stay true to the recording, but a
scrubber drawn at true amplitude is a flat line for anyone who recorded
quietly.

## Sentence highlighting is search, not arithmetic

The playhead highlights the sentence inside the turn, which needs to know where
each ASR sentence sits in the turn's text. `turns.json` and `transcript.json`
are written together, so the ranges could be rebuilt by repeating the join that
`Merge.turns` does, but an **imported** recording's turns were assembled by the
Python pipeline and its sentences would then land one word out.

`Merge.sentences` therefore searches the turn text for each segment's text,
carrying a cursor forward so a repeated sentence matches the right occurrence,
and skips anything it cannot find. Measured over the real library, 22
recordings and 12,600 segments: **12,596 located, every turn but one covered**.
The four misses are one-word segments whose text occurs earlier in the same
turn, and a miss costs that sentence its highlight and nothing else, which is
the point of skipping rather than guessing.

Sentences and not words because that is the finest timing mlx-audio exposes.
See the note above; if word timings ever arrive, this function takes a finer
input rather than being replaced.

## The sentence field wraps, and still opened one line high

Right-clicking a sentence and choosing Edit Sentence puts an `NSTextField` where
that sentence was. It was built with `usesSingleLineMode = false`,
`lineBreakMode = .byWordWrapping`, `cell.wraps = true` and
`maximumNumberOfLines = 0`, which is the whole list, and a sentence longer than
the pane still opened as **one line with the rest scrolled out of sight**: the
field editor held all of it, so arrowing through moved a caret over text nobody
could see, and correcting a word in the first line of a three-line sentence
meant editing blind.

Those settings say how the text wraps. They do not say how tall the field is.
That comes from `intrinsicContentSize`, and an `NSTextField` measures one line
unless it is told how wide the text may run, which is `preferredMaxLayoutWidth`
and is exactly the trap already recorded against the empty-state label in
`DetailView`. The field is handed its width by the stack it goes into, so there
is nothing to set it from at the moment it is built.

`SentenceField` is the fix and it is three overrides:

- `layout` keeps `preferredMaxLayoutWidth` level with `bounds.width`, before
  `super`, so the height reported this pass is the one for the width this pass
  was given. This is what makes the field re-wrap and grow when the window is
  narrowed underneath it.
- `intrinsicContentSize` measures a **copy** of the cell, loaded with the field
  editor's string. While an editor is up the cell still holds the text editing
  began with, so measuring the cell itself would freeze the field at the height
  the sentence had before a word was typed. The copy carries the font, the bezel
  and `wraps`, so `cellSize(forBounds:)` comes back with the insets included.
- `textDidChange` invalidates it, because the wrapped line count changes as
  somebody types.

`beginEditing` also sets `preferredMaxLayoutWidth` from `body.bounds.width`
before the field is added. The body has been on screen for as long as the
paragraph has, so its width is the one the field is about to be given, and
saying it there is what makes the field *open* at the right height instead of
appearing as one line and growing a pass later.

Measured on the built app against a scratch library, three lines of sentence in
a 1022-point window: opens three lines tall, grows to four as text is typed with
the caret and the dimmed context below both following, re-wraps to six when the
window is dragged to 760, and a short sentence still opens as a single line.

## Building the mixdown on the main thread froze the first press of play

`Mixdown.make` reads both tracks and encodes an m4a, which for an hour-long
meeting is seconds of work. It used to run inline in the button's action, so
the window locked up with the play button stuck down and no sound. `withPlayer`
now does it on a detached task and creates the `AVAudioPlayer` back on the main
actor. The view keeps its own `position` rather than reading the player's, so
scrubbing moves the playhead immediately and the player is told where to start
when it finally exists.

## The narrowed transcript is a view state, never a filtered array

`DetailView.soloed` hides the turn views that are not that speaker's and leaves
`turns`, `sentences` and `turnViews` whole and the same length.

This is not tidiness, it is the bug the obvious implementation ships with.
`refresh` finds the turn being spoken with `turns.firstIndex { ... }` and uses
that index into `turnViews`, twenty times a second, and `TurnView` writes an
edited sentence back by the segment index `Merge.sentences` gave it. Rebuild the
stack from a filtered list and both of those are addressing different objects:
the playhead highlights somebody else's paragraph, and a correction lands on the
wrong segment. `NSStackView` collapses a hidden arranged subview for free, so
there is nothing to gain by filtering the data.

Two consequences that were nearly bugs:

1. **`reveal` skips a hidden turn.** It runs from `refresh` to keep the playing
   paragraph on screen, and while somebody is soloed most turns are hidden, so
   without the guard the moment before a skip scrolls the reader to a collapsed
   view somewhere else in the meeting.
2. **`renderTurns` re-applies the solo at the end.** Correcting a sentence
   re-renders, and a re-render that quietly put everybody back would undo a
   filter nobody had asked to leave.

`scrollTranscriptToTop` came out of `renderTurns` for this, and has to stay
deferred: soloing hides most of the arranged subviews, and the stack has not
shrunk to fit what is left until the next layout pass.

Playback while soloed runs through that speaker's turns and skips what is between
them, which is the only place in this app where pressing play does not play what
comes next. It is therefore **stated on the bar over the transcript** rather than
left in a tooltip: a player that silently jumps is one you stop trusting. The bar
carries no button, because the filter lasts exactly as long as the popover that
set it. See `.agents/notes/speakers.md` for why that is the whole design.

## The waveform dims everybody but one, and that is where a quiet speaker is

`WaveformView.soloed` draws that speaker's bars in their ink and everybody else's
in `quaternaryLabelColor`.

The bars have been coloured by speaker since `spans` arrived, which means a quiet
participant was already on screen **and already invisible**. This library holds a
97 minute call where one speaker talks for 0.0 minutes and another for 0.1: at a
bar every three points that is a handful of pixels in one of five colours, and
finding them was a scroll through the transcript. Greying the other four turns
the scrubber into an index of exactly where that person is.

**Applied to the unplayed bars as well as the played ones**, which is the whole
point. The question is asked before anything has been listened to, so a highlight
that reached only as far as the playhead would answer it nowhere. Inside the
played part everybody else keeps the played grey rather than their own colour,
because five colours next to each other is the picture that made a quiet speaker
hard to find in the first place.

`speakers(for:)` came out of `runs` so both passes walk the spans once and cannot
disagree about which bar belongs to whom. It returns **empty** rather than a row
of blanks when there is nothing to say, because a blank speaker means a silence
between two turns and is a different claim: both callers test emptiness to fall
back to the single accent fill, which is what a recording with no transcript, or
one whose duration has not arrived yet, still gets.

## The to-do list is a lens, and deliberately not a status on every row

A row above the sidebar's list counts the recordings waiting on a name and is
gone entirely when the count is zero.

**A status on the rows is what this replaces, and it was removed on purpose.**
`Recording.stateText` records why: an unnamed speaker reads as "Speaker A" in the
transcript, which is legible on its own, so the list was telling people to go and
fix something that did not look broken. That argument still holds. What was
actually missing was never a badge on thirteen rows, it was one sentence saying
the thirteen exist, and the difference between those is the difference between a
to-do list and a nag.

So it is `Lens.unnamed`, alongside the speaker and tag lenses and ANDed with
them, and the row is one way to set it rather than a state of its own.

Four things about the row:

1. **Counted from the unfiltered library**, so it goes on saying how much work
   there is while a search narrows the list to something else. A count that moved
   with the search would read as zero the moment somebody typed.
2. **Hidden while the lens is on**, because then the list *is* the answer and a
   row offering to show what is already shown is a control that does nothing. The
   lens pill is what turns it back off.
3. **Collapses to nothing, spacing included**, the way the lens row above it
   does. A hidden view keeps its frame, and a library with nothing outstanding
   has to look exactly as it did before this row existed.
4. **View gains a menu item too**, with ⌘U. The row is absent exactly when the
   question can no longer be asked from it, and "which recordings do I still owe
   a name to" is worth being able to ask of a library that currently answers
   none.

Verified against a scratch library of six recordings, four holding an unnamed
voice and one with no transcript at all: the row read "4 recordings need a
speaker", and the lens took the list to those four. The transcript-less one
correctly does not count, because it is queued or it failed and the sidebar
already says so out loud.

`Labelling` is where the predicate lives, and it does not read `metadata.state`.
That measurement is in `.agents/notes/speakers.md`; the short version is that the
field is wrong in both directions and `effectiveState` inherits it.

## A hidden view held the divider, and the sidebar would not drag at all

In the recordings collection only, the sidebar could not be resized. People and
Notes dragged normally, so it read as something about the recording list, and it
was not: it was `TranscribingView`, in the *other* pane, hidden.

Measured on the running window with the accessibility API, which is what turned
a vague "it will not drag" into a number. The split group's `AXSplitter` exposes
a settable `AXValue`, so the position can be set from outside the app and read
back, and the window's `AXSize` can be set the same way:

| | divider | window width accepted |
|---|---|---|
| Recordings | 468, whatever it was set to | 799 to 1168 only |
| People | anything from 280 to 468 | 700 to 1573 |

A pane pinned to exactly 700 points, and a window that would not grow past 1168
or shrink below 799, is not a divider that ignores a drag. It is a required
width somewhere, and 700 is 620 plus two 40 point margins:

```swift
transcribing.widthAnchor.constraint(lessThanOrEqualToConstant: 620)   // required
let width = transcribing.widthAnchor.constraint(equalTo: widthAnchor, constant: -80)
width.priority = .defaultHigh                                          // 750
```

The intent was `Pane.widthCapped`'s trick: a soft equality against a required
maximum resolves to the smaller of the two. What was missed is that the engine
had a second way to satisfy the equality. With the pane at 900 the view wants
820, the cap says 620, and the violation shrinks either by narrowing the view or
by **narrowing the pane** to 700. The pane costs less, because the only thing
holding it is the divider position, and `NSSplitViewItem` holds that at its
`holdingPriority`: 250 and 260 here, both far below 750. So the constraint won
every layout pass, silently: there is no "unable to satisfy" log, because
nothing is unsatisfiable. It simply resizes something you did not mean.

It also outranked `maximumThickness = 460`, which is why the sidebar sat at 468.

**A hidden view keeps its constraints as surely as it keeps its frame.** This
view is only visible while a recording is being transcribed, and it was doing
this all the rest of the time. It was invisible in People and Notes because the
view is only in the recording pane, and invisible while transcribing because
then the picture is the width it asks for anyway.

The fix is one line: `width.priority = NSLayoutConstraint.Priority(200)`, below
both holding priorities. Verified the same way, in all three collections: the
divider now moves between 298 and 468 and stays where it is put across a
collection switch, and the window resizes freely again.

**Anything constrained against a pane's own width is a candidate for this.**
The others in this app are all inside a scroll view, which breaks the chain:
`stack.width == scroll.width` cannot push back on the window because a document
view does not size its scroll view. `transcribing` is a direct child of the
pane, which is what made it different.

## The gear and the way out are in the title bar, and the rows they replaced are gone

Every collection's sidebar used to end in a Settings row above a hairline, built
by one `sidebarSettingsRow` helper, and settings mode began with a "Library" row
hand-aligned to the traffic lights by `alignToTrafficLights`. Both are gone. The
title bar holds them now, in the region before `sidebarTrackingSeparator`, which
is the only way to reach the space over the sidebar:

- **Recordings, People, Notes**: masthead, flexible space, gear, collapse
  control. The gear is a peer of the collapse control because both are about
  this pane rather than about the recording beside it.
- **Settings**: the word "Settings" in the masthead's slot, flexible space, a
  Back button in the collapse control's slot. Settings locks the sidebar open,
  so that slot is free, and the screen has no other title.

Three things measured on the running window:

1. **The sidebar's minimum is 290 points now, and it is a title bar number.**
   The masthead, the gear and the collapse control are 100, 44 and 44 points
   side by side: below 290 the toolbar drops the gear into the overflow chevron,
   which parks it at the far right of the *content* pane. The old 200 was never
   reachable anyway, because the segmented control at the top of every
   collection is 280 wide at its intrinsic size and a control resists
   compression harder than a divider holds a position.
2. **A collapsed sidebar gives that region a fixed budget**, and it is about
   190 points. Measured: a 100 point masthead plus two 44 point buttons fits,
   106 puts the gear in the overflow menu at the far right of the window. So the
   masthead is `mark.fittingSize.width` rather than a stated number, and the six
   points of inset at each end of the mascot and the word are paid for out of
   the slack the hand-written `92` was carrying.
3. **`NSBezelStyleGlass` is macOS 26 and later**, so the Back button asks for it
   behind `if #available` and falls back to `.rounded`. It is the one button in
   this window with a bezel, and drawing it in the old one beside a row of glass
   toolbar items is worse than the availability check.

The mascot needed six points of left inset inside the masthead: with the sidebar
collapsed the system draws that item on glass, a pill fits itself to the view
inside it, and a filled circle reaches its own edge while the word beside it
keeps the side bearing its letters come with.

## The recording panel can be put away, and the dismissal has to survive a menu rebuild

`RecordingIndicator` floats over the top right corner for the length of a
meeting. That is the whole point of it: a menu bar item is 16 points wide, on a
display nobody is looking at, and possibly behind a notch, and believing you are
recording when you are not is the most expensive mistake this app can make. It
is also the reason it gets in the way, because the top right corner of a call is
where the other person's screen share puts the thing they are pointing at.

So the panel carries a `minus.circle` at its trailing edge, after Stop, and
pressing it orders the panel out for the rest of this recording. Three things
about it are not free choices:

1. **The dismissal is sticky, and it has to be.** `show(_:)` is called again on
   every capture change, and `AppDelegate.rebuildMenu` fires one for reasons
   that have nothing to do with this panel: the menu bar image, the sidebar, the
   toolbar. A dismissal the next rebuild undid would last until the next timer
   tick, which is not a dismissal. `isDismissed` guards the top of `show`, and
   `hide()` clears it, so the flag belongs to one recording and the next one
   starts visible.
2. **A question outranks it.** `show` clears `isDismissed` when
   `state.asksAQuestion`, and the minus is hidden in that state. "Are you in a
   meeting?" decides whether the recording is kept, this panel is the only place
   the answer can be given, and a suppressed question is a recording deleted or
   kept by default with nobody asked.
3. **The way back is a menu row, because the panel cannot offer one.** The
   status menu grows "Show Recording Panel" under Stop Recording, and only while
   `indicator.isDismissed`: a row offering to show what is already on screen is
   noise. `showRecordingPanel` calls `reveal()` and then `rebuildMenu()`, so
   nothing but `rebuildMenu` ever decides which state the panel comes back in.

The button is image-only and borderless, and its frame is `M.hide` (20 points)
rather than `sizeToFit`. An image-only borderless `NSButton` is exactly as
clickable as its image, and a 13-point target sitting 8 points from Stop is a
misclick on Stop, which ends the meeting. It is also deliberately quieter than
Stop: between the two controls on this panel the consequential one should be the
one that looks like a button.

The tooltip is load-bearing. A minus beside the word "Recording" reads as
"remove this recording", and that is the guess this app can least afford anybody
to test, so it says "Hide this panel. The recording keeps running."

The trailing furniture is now placed by a cursor walking right to left rather
than by each control computing its own origin from `width`. Three items deep,
the arithmetic in each frame had to know about every item after it, and that is
how the first version of this panel put a label underneath a button.

One thing this cannot be checked with: the panel is a borderless
`.nonactivatingPanel` and does not appear in `AXWindows` at all, so the
accessibility route in CLAUDE.md does not reach it. `LISTEN_PANEL=recording:598`
plus a synthesised click at the button's screen point is what verified it, and
the confirmation was the *installed* app's panel appearing underneath once the
one under test ordered itself out.

## The poll owns every control on the setup pane, so nothing else may set one

`Onboarding.updateControls()` runs on a 0.8 second timer, and whatever its
switch assigns is what the button says half a second later. The model step used
to be driven from two places: `download()` set the title to "Downloading…" and
disabled the button, and the very next tick put "Download Parakeet v3 (2.51 GB)"
back and re-enabled it.

**What that looked like to somebody using it, in their words: "for some reason I
can't download it", and no, no error message.** Two and a half gigabytes were
arriving the whole time. Reproduced against the shipped 0.7.0 build through the
accessibility API: the button reads its original title and is enabled 0.3 s,
2 s and 5 s after being pressed.

The rest follows from there. A button that looks unpressed gets pressed again,
and setup had no guard against a second fetch: each press built its own `ASR`
and its own `resolveOrDownloadModel` over one directory. The same run's log:

    Downloading model mlx-community/parakeet-tdt-0.6b-v3...
    Cached model appears incomplete, clearing cache...
    Downloading model mlx-community/parakeet-tdt-0.6b-v3...
    Cached model appears incomplete, clearing cache...
    Downloading model mlx-community/parakeet-tdt-0.6b-v3...

`clearCaches` is `removeItem` on the model directory. One task deletes what
another is about to read, and the reader reports `Key <some weight> not found in
ParakeetModel…`, which is what reached the tester as the entire explanation. A
later task then finished, advanced the pane, and the failure alert appeared over
"You are set".

The step now reads its state from `ModelDownload`, which refuses to start a
second fetch and can be watched by the Settings pane at the same time.
Everything on the pane is derived in `updateControls` from that one status: the
title, whether the button is enabled, whether the radio buttons are, the
progress bar and the line under it. The bar and line are updated **in place**,
never through `structuralKey()`: a percentage in that key rebuilds the radio
buttons under the cursor once a second for the length of a download, which is
the same trap the elapsed clock is kept out of it for.

`ModelDownload.onChange` is deliberately not used here. It is a single slot and
the Settings pane claims it, so two owners is a bug waiting for whoever opens
Settings and then runs setup again. The poll was already running; it reads.

## Continue on the model step means the model loaded, not that a file is the right size

Setup used to check `isDownloaded`, which is a directory size. So after a failed
attempt the primary read "Try again", the attempt had left a directory of about
the right size behind, and pressing it walked past the model step to "You are
set" without loading anything. A tester finished setup that way, holding a model
that had just refused to load, and only found out at the first recording.

Continue and Download are now the same action: resolve, load, and advance only
on a load that returned. From a warm cache that costs a second or two, and it is
the only check with any meaning behind it. Verified by staging a copy of exactly
the right size whose header does not parse: the pane stays on the model step,
says so in red, and offers Try again, which replaces the copy.

## The notes prompt is not inside the notes pane, and stayed up over an empty one

Stopping a recording left "What you are thinking. Only you write this, and an
agent can read it." across the top of a detail pane whose middle read "Select a
recording." Two separate facts have to line up to produce it, which is why
neither half looked wrong on its own.

A live recording forces the pane into Notes (`show`), because a meeting being
made now has no transcript and cannot have one for an hour, so the note is the
only thing on that screen anybody can use. The mode then survives the selection
change, deliberately: reading notes down a list of meetings is a mode, not a
choice to repeat. When the recording stops, `LibraryWindow.reload` finds nothing
selected in the sidebar and calls `detail.show(nil)`, so the pane is in Notes
with no recording.

`setChromeHidden(true)` is what that path uses to clear the pane, and it hides
`notesScroll`. But `notesPlaceholder` and `noteInfo` are **siblings** of the
scroll view rather than subviews of it: the placeholder is a label positioned
behind the text view's caret (an `NSTextView` has no placeholder of its own),
and the provenance line is above it by the same argument that keeps it out of
the editable text. Hiding the scroll view therefore takes neither with it.

`show(nil)` is also the only route that never reaches `applyShowing`, which is
where both are otherwise decided. So they kept whatever the last recording left
them at, and for a recording being made that is "visible": an invitation to type
into a note belonging to no meeting, over a sentence saying no meeting is open.

Both now answer `recording == nil` first, and `setChromeHidden` calls
`updatePlaceholder` and `showProvenance` in its hidden branch rather than
setting `isHidden` on them itself, so the two functions stay the only owners of
those views. The general shape is worth remembering past this pane: a view that
is *positioned against* another view is not hidden by it.

### Stopping a recording is a reload, and it wiped the name being typed

Reported from a real recording: a title and a note were typed while it ran, Stop
was pressed, and only the note survived.

Three things are true at once, and the bug is their product:

1. A title is written on the commit and a note is written on every keystroke.
   `controlTextDidEndEditing` is the only caller of `Recording.rename` from the
   window, and it fires when the field gives up focus.
2. Nothing outside the pane takes that focus away. The rule in `appkit.md` is
   that a text field does not stop editing because you clicked away, and every
   control *inside* the pane calls `endEditing` for it. The toolbar, the menu
   bar and the floating panel are not inside the pane, so pressing Stop left the
   caret exactly where it was.
3. `LibraryWindow.reload` re-shows the selected recording from disk, and
   `DetailView.show` assigned `titleLabel.stringValue` unconditionally. Stopping
   a recording calls `reload` twice over, so the field was overwritten with the
   stored title while somebody was typing into it.

`saveYours()` had been at the top of `show` since the notes pane existed, which
is exactly why the note came through. The title had no equivalent.

Three changes, and each one closes a different half:

- `show` calls `endEditingTitle()` before `self.recording` moves, but **only
  when the recording is actually changing**. Committing on every refresh would
  take the caret out of the field mid-word.
- `show` leaves `titleLabel.stringValue` alone when the same recording is being
  re-shown and the field has an editor. A refresh is not an instruction to
  discard what is in a field.
- `stopRecording` calls `LibraryWindow.commitEdits()` **before** `Capture.stop`.
  Order matters: `stop` re-reads `metadata.json` precisely so a title typed
  during the meeting survives, so the name has to be on disk before it looks.

The general shape: a pane that re-reads from disk on a timer or a notification
has to know the difference between "show me this recording" and "show me this
recording again", and only the first one may overwrite a field.

## The meeting page's largest gap was a row holding nothing

Between the speaker chips and the "Notes" heading sat 50 points of nothing, and
there was no view there to look at: `modeBar` is 24 points tall with 14 above
it, and both of the controls in it are permanently hidden. The mode picker went
when the page started naming its two halves with headings, and the note switcher
went with it. The bar is collapsed from the start now, and kept rather than
deleted because a second document mode is where it would go.

The rest of the page was measured against it in the same pass, because a gap
only reads as wrong next to a gap that is right:

| between | was | is |
|---|---|---|
| chips and "Notes" | 50 | 16 |
| "Notes" and the note | 12 | 8 |
| an empty note and "Recording" | 72 floor + 14 | 44 floor + 16 |
| the player card and the first turn | 28 | 14 |
| a paragraph and the next speaker | 26 | 18 |

The last one is the one worth remembering: what separates two turns is the sum
of **three** numbers, the turn's own bottom padding, the stack's spacing and the
next turn's top padding. Trimming only the stack's spacing, which is the number
with a name, never moved much and made the turns look pinched instead. 4, 10 and
3.

Both section headings now sit 16 points below whatever is above them, because
"Notes" and "Recording" are the same kind of thing and were 50 and 14.

## The drawer was never laid out until agent detection finished

For about a second after launch the window showed the word "Button" next to two
empty glass circles, over a squashed composer well.

Everything about the drawer is decided in `applyHeight`: its height, whether the
header exists, whether the panel is drawn, and whether `ComposerWell` has been
given a layout pass since its bounds last moved. Nothing called it until
`AskView` reported a height for the first time, and that report came from
`updateStatus`, which returns early while agent detection is still running. So
the first frame wore the height the drawer was *built* with, 84 points, and a
header nobody had told to collapse: `titleButton` and the two size discs were
drawn around a zero-height header, and "Button" is AppKit's placeholder title
for an `NSButton` that has none.

Two changes, and both are needed. `updateStatus` reports a height in its
"looking for an agent" branch as well, so the bar is the right size before
anything is known. And `loadView` ends with one `applyHeight()`, which is safe
there and nowhere earlier: it reads `container`, set at the top of that method,
and never `self.view`, which would re-enter `loadView` and hang the app with no
window.

The general shape is worth keeping: **a view whose geometry is decided by a
method has to have that method called once at build time.** Waiting for the
first real event means shipping whatever the initialisers happened to leave.

## A meeting being transcribed is a loading state, and three things were still on it

The page for a recording the queue is running showed the transcription picture in
the middle of it, and around that: the Notes heading with its "What you are
thinking" invitation, the player card with a transport for audio whose transcript
does not exist yet, the "Recording" heading, and the composer offering to answer
questions about a meeting nothing can be read from. Measured by looking at an
hour-long call at 82%: four empty regions around the one live thing.

`DetailViewController.isLoadingTranscript` names the test once, and it is the one
`updateEmpty` was already making to decide whether to draw the picture at all
(`showPicture`), so nothing can now disagree about whether this is a loading
state. `applyShowing` hides the notes half, the player and the transcript heading
from it; `updatePlaceholder` hides the invitation, and it has to be there rather
than in `applyShowing` because it runs last and would otherwise put it back.
`LibraryWindow.updateComposer` takes the composer away, which is the same
sentence it already applies one step earlier, to the meeting being recorded.

**The heading needed the loading test rather than `turns.isEmpty`.** Transcribe
Again replaces a transcript that already exists, so the page has turns and the
word "Recording" stood alone over a picture, naming a document that had just been
taken off the screen.

**The note box's height is re-measured on the way back, not remembered.**
`applyShowing` kept `notesHeight.constant` as it was whenever the page was open,
which was right while the only way to lose the note was to select nothing:
selecting a recording again re-renders the note, and rendering re-measures. A job
finishing does neither, because it is the same recording with the same note, so
`reloadNotes` finds the signature unchanged and skips the render. A height zeroed
on the way in would have stayed zero with the note hidden inside it. It calls
`sizeNotes()` instead, which is the same measurement rendering makes.

`LISTEN_PANEL=transcribing:0.6` had to learn about it too. The preview draws the
picture on a recording the queue is not running, so every test above was false
and it drew the *old* page around the picture: a preview of a state the app is
never in. `previewingTranscription` makes `isLoadingTranscript` true for the
length of the preview, which is what `previewRecording` does by hand with
`showsComposer`.

## The ellipsis said "No recording selected" over a note, because the menu was the recording's

`LibraryWindow.menuNeedsUpdate` was written when the sidebar listed recordings
and nothing else, so it asked one question, `selected`, and said "No recording
selected" to everything that was not one. The one list put notes and people in
the same column, and the sentence stopped being true rather than becoming wrong:
a note page really has no recording, and a control reporting the state of a
different screen is how a page comes to look unfinished. Reported from the note
page with Close above it, which is the giveaway, since Close knew perfectly well
that something was open (`sidebar.hasSelection`) while the line under it said
nothing was.

So the menu is the open page's, in the order the sidebar clears its own state:
`selectedNote` first, because a note selected while `selectedRecording` still
held the last meeting is exactly what `onSelectNote` prevents, then
`selectedPerson`, then the recording. The person's rows are filled by the pane
that owns them, `PersonPane.appendActions`, split out of its own
`menuNeedsUpdate`: two menus of verbs on one card that could disagree is the
same defect one screen along.

A note's verbs are short, because a note is a small artifact: Open Conversation
when there is one (`Chat.wrote`), Show in Finder, Delete. Delete is the reason
the menu is worth having at all. A note could be written from the window and
only deleted from the CLI or by an agent, which is a verb the user did not have.

**The row menu had the same bug with a sharper edge.** `SidebarViewController`'s
right-click selected the clicked row only when it was a recording, from when
those were the only rows, so right-clicking a note left the selection on the open
meeting and put *that meeting's* red Delete over a note somebody was pointing at.
It now selects anything the table itself would select, which is every row that is
not a day heading.

**And the alert had to stop asking twice.** An agent's note is titled from the
prompt, so its title is usually a question, and the recording alert's
`"Delete \(title)?"` came out on the first one tested as `Delete what are open
items with Edgar??`. `askingToDelete` quotes a name that ends in its own
punctuation and drops the extra mark.

Measured through accessibility on the built app against a scratch library, with
the note page open: menu rows Close, Open Conversation, Show in Finder, Delete;
alert `Delete “what are open items with Edgar?”` over "The note file is deleted
from disk. This cannot be undone."; after confirming, the row is gone from the
list, the file is gone from `notes/`, and the toolbar is back to the home page's
(Settings, Sidebar, Chats, Record, Actions). The same pass on a person picked out
of the one list reads Close, Edit, Merge…, Delete where it used to read "No
recording selected".
