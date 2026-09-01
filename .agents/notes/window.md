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

## The three collections are one list, and the switch is a word you type

The whole of the section below is history now: `LibraryCollection`,
`CollectionPicker`, `PeopleNav`, `NotesNav`, `Mode.people` and `Mode.notes` are
gone. Read it for why the segmented control existed, because the constraint that
produced it is still true: a note about four meetings has no home in a
recording-centric sidebar, and without somewhere to put it the app can create
something it cannot show. What changed is the answer, not the problem.

**A segment is a place you are in and have to leave; a lens is a state with an
off switch.** That is the whole argument and everything else follows from it.
Three consequences the tab set could not avoid:

1. **It could not say "all three".** There is no All segment and there was never
   going to be one, so the one list that answers "where did I see that" had to
   be assembled by looking in three places by hand.
2. **An empty collection read as a broken control.** Pressing Notes on a library
   with none gave a blank pane, which is indistinguishable from the click not
   working. A `kind:notes` pill over an empty list is an answer.
3. **Search meant a different thing in each of three states**, because it scoped
   to the active segment. The placeholder had to say so ("Search people"), which
   is a control explaining itself in a 280 point column.

What replaced it, in the order the moves are worth making:

**The section heading is the filter.** `SectionHeader` is the heading and the
control that narrows the list to it, with an "Only these" hint that appears
under the pointer. Gmail and Drive grow a row of filter chips under the search
box because a mail list has no sections to hang them on; this list has three, so
the affordance was already on screen and needed no new chrome. It is the whole
of the discoverable route to the kind lens.

**Sections are by kind while you are searching and by day while you are
browsing.** This is a real added claim and the one to look at first if any of
this feels wrong. Chronology is what you want from a library and kind is what
you want from a result set. It is also what makes the heading affordance
possible at all: notes are sorted into the days beside recordings, so before
this there was exactly one heading in the list that named a kind and the
heading-as-filter could only ever have worked for People. `sectionsByKind` is
the flag, and the day moves into the row's subtitle when it is on, so nothing is
lost with the heading that carried it. The cost is that the list visibly
reorganises itself on the first character typed, which is a bigger motion than
anything else here.

**`kind:` and `is:` join `tag:` in the field**, parsed by `RecordingFilter.parse`
against `LibraryKind`. Both words, because `is:` is the muscle memory from
GitHub and Gmail and `kind:` is Spotlight's. A value neither recognises stays in
the query rather than being swallowed, so a typo searches for itself instead of
silently filtering on nothing.

**A finished operator lifts out of the field and becomes a pill.** The field
holds free text and the row under it holds operators, and nothing is ever in
both: the pill row already existed as *the* place that says this list is not the
whole library, so leaving `tag:kinsight` in the field would state the same fact
twice in two places that can disagree. That is Drive's choice rather than
Gmail's, forced here by a control that was already on screen. See
`liftOperators`, and the trap under it.

**Backspace at the head of an empty field puts the last pill back as text.**
This is the half that stops the lift feeling like a fight: without it a token
can only be dismissed, so a mistyped tag means clicking the pill and typing the
whole operator again, and the field appears to eat what you wrote. `Lens.typed`
is what makes it possible, and a pill that cannot be written back is a pill you
can only delete.

**The options live in the magnifier, not in a standing chip row.**
`NSSearchField.searchMenuTemplate` costs no width, which a row of chips does not
have to give in 280 points with a to-do row and a live recording already
competing for the top of the list. Every item names the operator it writes
(`People   kind:people`), which is the one thing Gmail's advanced form gets
right and its chips do not: the discoverable route teaches the typed one instead
of being a parallel way to do the same thing.

### The heading is a button, and it is the first one in this app that answers to accessibility

`SidebarRow` and `HoverRow` are plain `NSView`s with a target and an action, so
no automation and no screen reader can press them. `SectionHeader` sets
`accessibilityRole`, a label and `accessibilityPerformPress`, which is four
lines, and it is how the whole of this was tested end to end through
`AXUIElementCreateApplication`.

**`setAccessibilityElement(false)` on the labels inside it does nothing.**
`NSTextField` answers that question itself. Measured through the tree: a section
read "Person, Person, Person", once for the table's own `AXCell` wrapper, once
for the header and once for the field inside it. `accessibilityChildren() -> []`
is what removes them, and the `AXCell` is AppKit's and stays.

### Three things about the search field that are not obvious

**`NSSearchField`'s `action` is far too late to edit the text.** It fires on
Return and on the field's own delay, by which time the caret has moved on.
`controlTextDidChange` is the only place an operator can be taken out from under
it, which is why the field has a delegate at all.

**`complete(_:)` is re-entrant.** It inserts text, which arrives back in
`controlTextDidChange`, which asks to complete the completion. `completing` is
the guard.

**Nothing may be preselected in the completion list.** `complete(_:)` inserts
the selected candidate as it opens, so a default selection types over the value
somebody is halfway through. `index.pointee = -1` is what stops it, and it is
the same mistake the lift had to be taught not to make.

**The magnifier's menu is a template, copied when it opens rather than consulted
live.** A menu built once in `loadView` lists the tags that existed at launch
for ever. `menuTags` is the last vocabulary it was built from, and `reload`
rebuilds it when that changes, which is rare.

## Collection navigation is in the sidebar, not the toolbar

**Superseded: see the section above.** Kept because the constraint is still
true and the reasoning is what the replacement had to answer.

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

## About is a window, and the website was in neither of them

`AboutPane` followed Speak's section for section: identity header, Updates,
Setup, Made by, Built on, then the licence and the source link. It was a
**settings section**, reached by "About Listen" switching the library window into
settings mode and selecting the last row of Advanced.

The report that ended that arrangement was somebody trying to pass the app on to
a friend and giving up. Two separate faults, and the second is the expensive one:

1. **"About Listen" did not open an About box.** Every Mac app answers that menu
   item with a small window carrying the icon, so a page appearing inside the
   main window behind a sidebar reads as the wrong thing having happened.
2. **The landing page was not in the app at all.** `AboutPane.websiteURL` was
   `maxgoespublic.com`, the author's site, and the only other link was the
   repository. The one page that says what Listen is and how to install it,
   `https://mugoosse.github.io/listen/`, was reachable from the README, the DMG
   and nowhere a user could click.

So `AboutWindow` is a window: 400 points wide, not resizable, closable, its title
bar transparent and empty. What is in it is the identity, the three links out
(Website, Docs, GitHub), one honest ask, and the credits. Every URL in the app
now comes from `Links`, which exists so the next place that needs the site
cannot invent a different answer, and `Sharing` is beside it.

Six things, each of which was got wrong or nearly missed:

- **The pane became Updates, and moved out of Advanced.** Leaving a section
  called About that no longer holds the website or the credits would send the
  next person looking exactly where the last one failed. `UpdatesPane` keeps the
  version check and Run setup again, which really are preferences, and sits in
  the App group: whether this copy is current is not an advanced question. It
  ends with an `About Listen…` button, so the route people already learned still
  arrives one press away.
- **No `Updates` heading inside the Updates pane.** The pane draws its title at
  22 points immediately above, and a 13 point repeat one line down reads as a
  mistake. The heading was correct while the section was called About.
- **The height is measured once, after a layout pass.** `stack.fittingSize` on a
  column of wrapping labels is only right once they have been given the width
  they wrap at, so `layoutSubtreeIfNeeded()` comes first and `setContentSize`
  second. Sized before that, the window opens several lines short and the
  licence paragraph is cut off.
- **`.inline` is a grey capsule, not a link.** The author's site was an inline
  small button, inherited from the pane, and under a person's name it reads as a
  disabled control. It is borderless with an accent-coloured attributed title
  now, which is also the only colour that sticks: `appkit.md` records that an
  attributed title's colour wins over `contentTintColor`.
- **The star glyph needs `imageHugsTitle`.** Without it the star sits against the
  leading edge of the button and the words centre in what is left. Third time
  this app has paid for that one.
- **`LISTEN_PANEL=about` shows it, and `LISTEN_SHOT` photographs it.** It is a
  third window, like the dictation pill, so `shootIfAsked` needed a third answer:
  without `previewingAbout` it photographs the library window, which nothing has
  opened. Note that `writeShot` flattens onto `windowBackgroundColor` under the
  *view's* appearance while the views draw under the *system's*, so a dark-mode
  shot comes out white on white and looks like a window that rendered nothing at
  all. It has not; `magick -level 92%,100% -negate` shows the layout, and a real
  `screencapture` shows the colours.

Two more, both reported the moment the window existed:

- **The settings sidebar needed a way back to it, and it is a button under the
  list rather than a row in it.** Moving About out of Advanced left the settings
  screen with no route to the window at all, and the menu bar cannot be the only
  one: somebody looking for what the app is looks in the app. It is not a table
  row because it is not a section. There is no pane behind it, a selected row
  would leave the list pointing at a page nobody is on, and a row that refuses
  selection cannot be reached by the keyboard or by accessibility at all.
  `SettingsNavViewController` pins an `NSButton` to the bottom of its container,
  the scroll view stops 8 points above it, and it is verified by `AXPress`:
  press, and a second window titled "About Listen" appears. That verification
  matters more than usual here, because a **synthetic click does not land in
  this app** and proved nothing either way, which is the whole of
  [[synthetic-pointer-events-do-not-verify-ui]] again.
- **One product, one site.** The author's own site was in the About box and in
  the iPhone's Settings because neither had a product page to point at. Both now
  do, at the top, and two sites on one card is the reader choosing between them,
  so `maxgoespublic.com` is a credit line and no longer a link. Speak went the
  same way for a stronger reason: its dictation is *inside* Listen, so "Speak,
  the other half of the pair" sent people to a download for something they
  already had. Nothing in the product names Speak any more, which
  `notes-tags-dictionary.md` records under the dictionary.

The Help menu and Cmd-W arrived with this, and both are in `appkit.md`: there was
no Help menu at all, which is the first place somebody looks for a website.

## The Updates pane follows the updater, not its own button

Sparkle answers a check in a window that is then dismissed, taking the answer
with it, and a scheduled check that finds nothing says nothing at all, so "am I
on the latest version" had no answer that survived closing a dialog. Two things
keep that answer on screen, and both were got wrong once:

1. **`refreshUpdates` does not call `resizeDocument`.** The result line appearing
   does change the pane's height, but `sizeDocument` already runs on every layout
   pass and a text field whose string changed schedules one. The public one also
   scrolls the pane back to its first control, and a scheduled check finishing
   while somebody is reading is not a reason to move the page.
2. **The pane observes `Updater.outcomeChanged` in `viewWillAppear` and stops in
   `viewWillDisappear`.** A check can be started from the menu bar or by the
   scheduler, so following the button alone would leave the pane showing the
   previous answer.

That second one was a single `onChange` closure until the gear grew a badge and
there were two followers. One closure means the second claimant silently
unhooks the first, and the symptom would have been the pane going dead exactly
when the toolbar started working, so it is a `NotificationCenter` post now.

## A toolbar item will not draw an image you hand it, and accessibility says it did

The gear in the library's title bar carries a badge when an update is waiting,
and getting it there took two wrong turns worth recording, because the first
one passes every test that is not a screenshot.

**A hand-composited `NSImage` does not render in an `NSToolbarItem`.** The first
version drew the badge: `gearshape` tinted to `labelColor` with a `sourceAtop`
fill, a ring punched out with `destinationOut` so the dot would not merge with a
tooth, an accent dot filled into the hole. Written to a PNG it is exactly the
wanted image, and that was checked. Assigned to `item.image` it does not appear:
the gear draws plain. It makes no difference whether the image goes onto a live
item or onto one built fresh by `rebuildToolbar`, nor whether `cacheMode` is
`.never`, nor whether `alignmentRect` is copied from the symbol.

**The trap is that the tool tip set two lines above it does take.** So the item
reported "An update is available. Settings (⌘,)" through accessibility, an AX
assertion on the badge passed, and the gear on screen was plain the whole time.
An indicator nobody can see is worth nothing, and only `screencapture` said so.
Anything about how a toolbar item *looks* has to be verified from pixels.

So it is `gear.badge`, a real SF Symbol, which AppKit tints, scales and lays out
itself. Two costs, both accepted. The resting icon is `gearshape` and this is
the toothed `gear`, so the outline changes along with the badge appearing, which
reads as deliberate rather than broken. And there is no `gearshape.badge`:
measured on this SDK, `gearshape.badge` and `gearshape.badge.checkmark` do not
exist, while `gear.badge` does.

**The badge is layer zero and the gear is layer one**, which is the opposite of
the reading order and was measured rather than assumed. A palette of
`[.labelColor, .controlAccentColor]` produced a bright blue gear with a white
dot, which is the loudest possible version of this. The right way round is
`[.controlAccentColor, .labelColor]`, checked in both appearances by rendering
the symbol inside `performAsCurrentDrawingAppearance` rather than by launching
anything.

One thing that is not a bug: captured while the window is not frontmost, both
layers come out grey, because AppKit dims a background window's toolbar and the
accent colour greys with it. Activate the app by pid before the shot, or read a
dim badge as inactive rather than as wrong.

Verified end to end against the real feed by pressing Check Now through
accessibility on a `LISTEN_PANEL=settings:updates` launch, which touches nothing
in the library: Sparkle's "You're up to date" window, then the green result line
and `Last checked Today at 15:30` in the pane behind it.

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

## Turns overlap, so the first one spanning the playhead is the wrong one

Reported as "I clicked a line, it played the right audio and highlighted the line
above it, and then played that line too". Half of it was the highlight and the
other half was the reader believing what the highlight said.

`refresh` used to take `turns.firstIndex { position >= $0.start && position <
$0.end }`. That reads as obviously correct and is not, because **turns overlap**:
people talk over each other, the two tracks are clustered separately, and
`turns.json` is ordered by start. So the first turn spanning an instant is the
*earliest one still running*, and a short interjection nested inside a longer
turn can never win. Measured on the call it was reported from:

| | |
|---|---|
| turns | 105 |
| starting before the previous one ends | 55 (53%) |
| clicking a turn's first sentence highlighted a different paragraph | **59 of 105** |
| the same, with the rule below | 0 |

The example: `Me` runs 218.22 to 226.46 and `Daniel` runs 220.74 to 223.22,
wholly inside it. Clicking Daniel's line seeks correctly to 220.74, the first
spanning turn is `Me`, so the paragraph above lights up, and the audio then plays
on into the rest of `Me`, which is the highlighted paragraph. Everything the
reader could see agreed with the wrong answer.

`DetailView.speakingTurn(at:)` ranks instead of taking the first:

1. **A sentence beats a span.** A turn runs from its first sentence's start to
   its last one's end and includes the silences between; a sentence is somebody
   actually talking. A turn with a sentence over the instant beats one that
   merely surrounds it.
2. **The most recently begun wins.** Where two turns are genuinely sounding at
   once, which is real in a meeting, the one that started talking last is what a
   listener hears as current.

Verified at runtime with `LISTEN_DEBUG=1`, playing through a turn nested inside
another: `playhead 00:19 -> turn 1 Céline Goossens` then `00:21 -> turn 0 Me`,
where the old rule never left turn 0. And seeking straight into an overlap lands
on the right paragraph on the first tick: `playhead 00:19 -> turn 1 A`. The trace
line is kept, since "which paragraph does the app think is playing" is otherwise
invisible.

`WaveformView.speakers(for:)` still walks its spans with a cursor and so tints an
overlapped bar with whoever started earlier. Left alone deliberately: a bar is
three points wide and two people talking at once is one bar either way.

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

## The transcript is never filtered, and the arrays are why it could not be

`DetailView.focused` names the speaker the pane is asking about. It changes what
the **waveform** draws and what the popover's own Play does, and nothing at all
about the page: no paragraph is hidden, nothing is inserted, nothing moves. The
filter it used to apply is gone, and so is the bar that explained the filter's
last surviving side effect; see "Asking about a speaker points the player at
them" and "The skipping belongs to the button that names it" in `speakers.md`.

The constraint that made the filter a view state rather than a filtered array has
outlived it, and is the reason nothing here may start filtering again. `refresh`
finds the turn being spoken with `turns.firstIndex { ... }` and uses that index
into `turnViews`, twenty times a second; `TurnView` writes an edited sentence
back by the segment index `Merge.sentences` gave it; `reassign` writes a
paragraph back by the time window `turns` gave it. Rebuild the stack from a
filtered list and all three are addressing different objects: the playhead
highlights somebody else's paragraph, and a correction lands on the wrong
segment.

Three things that went with the filter and the bar:

1. **`reveal` no longer skips hidden turns.** The guard existed because most of
   them were hidden while a popover asked about somebody, so a skip could scroll
   to a collapsed view somewhere else in the meeting. Nothing is hidden now.
2. **`setFocus` no longer scrolls.** Jumping to the speaker's first turn made
   sense while the rest of the page was being taken away. With the page intact it
   is a click on a name throwing away the reader's place.
3. **`applyFocus` is gone entirely**, along with `focusBar`, its label and its
   two constraints. The transcript, the live view and Ask now hang off
   `playerCard.bottomAnchor` directly, at the constants they had while the bar
   was collapsed, so the pane is laid out identically to how it looked with
   nobody being asked about.

The lesson worth keeping is about **where a status line may live**. A sentence
under the player is a row of layout that every view below it inherits, so a
state that turns on and off with a click makes the whole page breathe. If
something like this is needed again it belongs inside the popover that caused it,
which is drawn over the page rather than in it.

## The waveform dims everybody but one, and that is where a quiet speaker is

`WaveformView.focused` draws that speaker's bars in their ink and everybody else's
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

## The to-do list is a lens, and the row that offered it was a nag

The row above the sidebar's list is gone. So are `SidebarRow`, the `rowInset`
and `rowEdge` constants and the factory that made them, which had no other
callers left once it went.

**Removed on request, and the argument is the one this note already made in the
other direction.** The row survived on the grounds that what was missing was
never a badge on thirteen rows, it was one sentence saying the thirteen exist.
That held while the row was the only way to ask. It stopped holding once the
lens was in the magnifier's menu, in the View menu on ⌘U and typeable as
`is:unnamed`: the row became the only one of the four that asks unprompted, on
every launch, for ever.

And it can never reach zero. Some voices in a meeting are never going to be
named, because nobody remembers who the fourth person on the call was, so a
permanent "5 recordings need a speaker" is a standing claim of outstanding work
against a number that will not come down. That is the difference between a to-do
list and a nag, and this note drew that distinction to justify the row before it
described the row that failed it.

**The count moved rather than going with it.** `is:unnamed` in the magnifier
reads "Needs a speaker  (5)", which is the same number in the one place you only
see by going to look. Absent entirely at zero, so an empty count is never
printed. It costs a rebuild of the search menu template whenever the number
changes, tracked by `menuWaiting` the way the tag vocabulary is tracked by
`menuTags`, and `Labelling.waits` is answered from a cache keyed on each
`turns.json` stamp so asking on every reload is a stat per recording.

What is below is the row's own reasoning, kept because two of its four points are
now the *lens's* rules and still apply.

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

## The note box reserved room for a button that left, and lost the last line of every note

The user's own note is an `NSScrollView` around an `NSTextView`, sized to its own
text between a 30 point floor and a 154 point ceiling (`sizeNotes`). It also
carried `contentInsets.bottom = RecordButton.clearance`, copied from the
transcript while the Record button floated over the bottom right of this pane.

**A content inset is not padding; it is scrollable range plus a smaller clip
view.** The scroll view keeps its frame, the clip view is the frame minus the
insets, and the scroller's track is what is left. So 24 points of bottom inset on
a box whose height is exactly its text meant the box could never show all of it.

Measured through accessibility on build 159, against a scratch library, in
`AXScrollArea` sizes (the clip, not the frame):

| Note | Box | Visible | Scroll bar |
|---|---|---|---|
| Empty | 30 | **6** | 19 x 8 |
| Three lines | 58 | **34** | 19 x 36 |

The last 24 points of every note were underneath nothing at all: scrollable to,
never on screen. On an empty note the writing surface was a 6 point strip, and
the 2 point knob left in an 8 point track is what showed up in the corner of a
screenshot as an unexplained sliver against the right edge. That sliver is what
this was reported as.

The button has been in the toolbar since "Move the record control to the corner
it acts in" was undone, and `RecordButton.clearance` says so, but this box was
wrong even while it floated: the note is 30 to 154 points tall between the
speaker chips and the player, and the thing that actually reaches the window's
floor is the transcript below it, which reserves its room with a spacer view at
the end of its stack rather than with an inset (`renderTurns`).

So the insets are zero on all four edges, with
`automaticallyAdjustsContentInsets` still off, because that is the trap directly
above it: setting any inset turns the automatic ones off, and AppKit's automatic
top inset here was 14, which is the air the placeholder and the caret are
positioned by. Stating zero keeps it stated.

`autohidesScrollers` went on at the same time. Nothing scrolls until a note
passes the ceiling, and the scroller was taking 17 points of width from the text
container to say so: the same three lines measure 1149 points wide before and
1166 after, so the note now lines up with the heading above it and the transcript
below it. After: empty note 30 visible of 30, three lines 58 of 58, no scroll bar
in the tree at all.

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

## The transcript's scroller is at the window's edge, and its margin is the document's

An overlay scroller rides the edge of its own scroll view, so where the scroll
view stops is where the scroller floats. The transcript's was inset 20 points on
both sides, which put its knob at `x 1483..1489` against a window edge at 1512:
23 points of air to the right of it, sitting over the dialogue rather than
beside it. Every Mac app that scrolls a document puts the scroller at the edge
of the window and the margin inside the text.

So the scroll view is flush with the pane now and the margins moved into the
document, as `DetailView.transcriptInsets`. They add up to exactly what was
there before, which is why no text moved:

- left: 20 (the scroll view's inset) + 4 (the stack's) = **24**, which is where
  every heading on this page already starts
- right: 20 (the scroll view's) + 20 (the document being narrower than the
  scroll view) + 16 (the stack's) = **56**, which is the same 24 of margin plus
  a 32 point gutter so a line of dialogue never runs under the scroller

Measured before and after, window 1512 wide, floor at y 982, a 140 point drawer:

| | before | after |
| --- | --- | --- |
| scroll area x | 318..1492 | 298..1512 |
| knob x | 1483..1489 | 1503..1509 |
| scroll bar y | 405..703 | 377..966 |
| knob at `value 1.0` ends at | 699 | 962, 20 above the window's floor |
| last paragraph at `value 1.0` ends at | 764 | 765 |
| first inked pixel of a paragraph | 330.5 | 330.5 |

The 16 points between the bar's end and the floor are AppKit's, not this app's:
an overlay scroller leaves the window's bottom edge alone.

## The room the composer needs is the transcript's, not the scroll view's

The drawer overlays the pane, so the last turn of a meeting sits under it unless
something says otherwise, and `contentInsets.bottom` was what said it. That
works and costs the scroller: it is laid out inside the content area, so a 140
point bottom inset ends the track 140 points above the window's floor, and a
knob resting there with empty window under it reads as scrolling that has not
finished. The room is now a spacer at the end of the stack, sized
`RecordButton.clearance + drawerCover`, which is the shape the record button's
clearance already used and for the reason written there: a view at the end of
the document moves only the end of the document.

Nothing about the reading moves. Measured on the same 2 hour meeting, the last
paragraph ends 218 points above the floor with the content inset and 217 with
the spacer, and text passed behind the drawer while scrolling either way,
because a content inset limits how far a document may travel rather than what
may be drawn over it.

`drawerCover` is a field because the transcript is rebuilt from its turns
whenever one is edited, and the tail is built with it, so the number has to
survive the rebuild. `automaticallyAdjustsContentInsets` is turned off in `init`
rather than left to the first call: it was on until the composer first reported
a height and off afterwards, which is a difference nothing should depend on.

## A drag across a paragraph starts playback, and playback moves the page

Two reports of the transcript scrolling away after a speaker edit, both from the
sentence menu and never from the pill, which is what made it look intermittent
until the difference was found: `show` stops playback and `reloadTranscript`
deliberately does not, because correcting a word is something people do while
listening.

What that left armed is `follows`, and **the gesture that arms it is the gesture
the sentence menu is opened with.** Selecting text begins with a click; a click
on a paragraph runs `onSeek`, which seeks there and plays. So a reader dragging
across four sentences to correct who said them has started playback without
asking for it, and a second or two later the playhead crosses into the next
paragraph, `refresh` reveals it, and the page goes with the playhead rather than
staying with the reader.

Three things came out of chasing it, and two of them are about measuring rather
than about the app:

- **`reloadTranscript` turns following off.** Editing is the reader saying they
  are reading. `reveal` already had the rule, in the words "if the reader has not
  gone somewhere else". The audio keeps playing, which is the whole point of that
  reload not being `show`.
- **The paragraph the playhead is in is named by when it starts, not by its
  index.** Every edit renumbers the turns, so an index comparison read a
  reassignment as the playhead arriving somewhere. See `DetailView.currentStart`.
- **`show` only re-arms `follows` for a recording that was not already on
  screen**, the same rule its `scrollToTop` follows and for the same reason: a
  speaker edit reloads through `show`, and re-arming there undid the reader
  having scrolled away.

The measuring lesson is worth as much. The first harness for this took its
"before" reading *before* pressing play, so it measured eleven seconds of
following and called it a jump, and two fixes were written against a
reproduction that was not the thing being reported. A reading taken on the wrong
side of the thing you are not testing is worse than no reading: it is confident.
The control that settled it was running the same script against the build the
user already had, which kept the place exactly, and that is what said the pill
path had never been broken at all.

## The transcript stack is unflipped, and its frames are zero until layout runs

Both halves of this were measured while trying to keep the reader's place by the
*paragraph* they were on rather than by a number of points, which is the better
idea in principle and is not in this view.

`NSScrollView`'s clip view here is flipped, so `contentView.bounds.origin.y`
grows downward and zero is the top: that is what `scrollTranscriptToTop` relies
on. The document inside it is a plain `NSStackView`, which is **not** flipped, so
the first paragraph has the *largest* `frame.minY`. A scan for "the last
paragraph starting above the viewport" therefore walks the document backwards
and lands on the first one every time. Traced on a 137 turn meeting:

    place: origin=4800 anchor=6.72 top=16234 views=137

The first turn, at 6.72 seconds, is 16234 points down the stack's own axis.

The second half is worse because it is intermittent. A speaker change rebuilds
the transcript twice, once for the edit and once for the sidebar reload that
follows, and the second rebuild reads the frames before layout has run, when
every one of them is zero:

    place: origin=4800 anchor=5340.04 top=0 views=137

Every frame compares equal, so the scan ends on whichever paragraph is last. The
page moved 214 points on the first edit tried, in the case where restoring a
plain offset is exactly right, because everything above the reader was
untouched.

So the offset stays. What made the anchor worth having was a sync pull rewriting
the transcript under the reader, and that is now impossible: see "A sidecar this
device has edited is not a sidecar it is behind on" in `cloud-sync.md`. What is
left that changes the document above the reader is `.discard`, which is rare,
deliberate and confirmed.

## Open at the top is the clip view's origin, not a point in the stack

`scrollTranscriptToTop` scrolled the stack's own `bounds.maxY - 1` into view.
For an unflipped view the top edge *is* its height, so that point is only the top
while the height is final, and this runs one pass after the turns are added with
their heights still to be solved against their width.

It was right for as long as the first layout pass happened to be the last one.
The spacer above gave the stack a second reason to grow, and a 2 hour meeting
opened 66% and 82% down on two runs out of three; the shipped build opened at the
top on three out of three. That is what a race looks like from the outside, and
the reason to check a regression against the build that does not have it rather
than against the reading of the code.

The clip view is flipped, so the top of the document is `y = 0` whatever the
document's height is, which is what `TopAlignedClipView` is for and what its own
note already said. `scroll.contentView.scroll(to: .zero)` with a
`reflectScrolledClipView` after it opens at the top on four runs out of four, and
does not depend on layout having settled at all.

## A reload that does not scroll still loses the reader's place

`renderTurns(scrollToTop: false)` was written for exactly this and did not do it.
It meant "do not scroll to the top **again**", and that is not the same as
staying put: the first line of it empties the stack, the document collapses to
nothing for a pass, and a clip view whose document is shorter than its own bounds
clamps its origin to zero. Putting the turns back does not undo that.

So every correction made an hour into a meeting answered by jumping to the top of
it, which reads as the app having lost the transcript rather than as a scroll
position. `renderTurns` takes the origin before it empties anything and
`restoreTranscriptScroll` puts it back, deferred for the same reason
`scrollTranscriptToTop` is deferred and clamped to the new document height,
because `.discard` can make the transcript shorter than the offset it was read
at.

**A speaker change goes through `show`, and `show` is right to open at the top.**
`reloadAfterSpeakerChange` uses it because a rename changes the title, the chips
and the sidebar row, not only the paragraphs. So the place is handed forward in
`keepingScroll` rather than taken out of either: the reload that means to open at
the top still does, and the one that is really an edit does not.

**One edit, one reload, and the second one was reading a clip view the first had
just emptied.** The picker's narrow path called `reassign`, which reloaded, and
then closed, and closing runs `reloadAfterSpeakerChange`, which reloaded again.
The second read the reader's place out of a clip view that had been clamped to
zero a moment earlier, so the pane kept its place and then jumped to the top
anyway. Measured through the window with the first paragraph's AX position: -6817
before the edit, 383 after. `reassign(reload:)` is false for that one caller.

**Three constants had to agree and only one of them said so.** The stack was
`scroll.width - 20`, every turn row was `stack.width - 20`, and the stack's own
`edgeInsets` were a fourth number. The row width is the stack's width less its
insets and nothing else, so it is `transcriptSides` now and derived from the one
place the insets are written. Adding a margin to a stack view does not narrow
what it arranges: `NSStackView` lays its arranged views out inside `edgeInsets`
but does not size them.

## The first run has no close button, and the re-run keeps one

Onboarding was `.closable` and `windowWillClose` counted as finishing, so
closing at the model step marked the install onboarded and a Dock click
raised the library: the first outside install did that mid-download and met
the app with no model chosen and no idea the wizard had counted it as done.
Every step already has its own way past (Skip, Not now, Later; the model
download continues in the background), so the close button's only real power
was vanishing the flow half-way. `show(closable:)` now drops it on a first
run and keeps it for the Settings re-run, where someone reviewing setup must
be able to leave without walking every step. `verify_onboarding.sh` walks the
whole flow on the uitest copy pressing only safe buttons (its `advance`
prefers Later/Skip/Not now and never presses anything that grants, opens
System Settings or turns sync on, because what each step shows depends on
what the machine has already granted).

## The record capsule asked for 36 points on a toolbar that had 28 to give

`RecordButton` is 36 points tall inside the macOS 26 glass toolbar. Pre-26
unified toolbars give a custom view item less, so the same number drew a
squeezed pill on a Sequoia Mac (seen on the first outside install, photo
against a Tahoe screenshot of the same window). `M.height` is now an
availability split, 36 on 26+ and 28 before, radius following. The 28 is
inferred from the standard control height, not yet measured on hardware: no
pre-26 Mac was reachable (mb-flame is on 26.6), so the first session that has
one should read the drawn height and write the measurement into the constant's
comment.

## The Ask settings pane opened blank twice a day, and the picker sat empty

`AgentPane` wiped its list and showed a bare "Looking…" on every open, with
the "Which one to use" popup empty until detection finished: a second or two
of the pane reading as broken, every time, for facts the process already
held. It now seeds rows and picker from `AgentCLI.cached` and lets the fresh
sweep land over them; the wipe-and-look state survives only for a genuinely
cold cache, where it gained a spinner and a pre-filled "Automatic" so an
empty popup never reads as a broken one. Asserted in `verify_ask_states.sh`
against the warm-cache open.

## Discard Recording was targeted at the window, and red hid that it was dead

The toolbar's actions menu is built by `menuNeedsUpdate` through one `add(...)`
helper, and that helper sets `item.target = self`. The one item offered during a
call was written as `#selector(App.discardRecordingFromUI)`: the selector belongs
to the app delegate, and `LibraryWindow` does not answer it. The menu leaves
`autoenablesItems` on, so AppKit validated the item against a target that does
not respond to it and disabled it.

A disabled item draws greyed, **except that this one carries an
`attributedTitle` in `systemRed`** because it is destructive, and an attributed
string's own foreground colour wins over the greying, the same rule `Hover`
records for buttons in `appkit.md`. So the item looked exactly as live as it
would have if it worked, opened its menu normally, and did nothing at all when
pressed. Found by a user mid-meeting who wanted to throw a recording away, not
by anything here.

`discardRecordingSelected` on `LibraryWindow` forwards with
`NSApp.sendAction(#selector(App.discardRecordingFromUI), to: nil, from: self)`,
which is how the record capsule already reaches `startRecordingFromUI` and
`stopRecordingFromUI` from this same class, and it is validated on
`selected?.isLive` beside `chooseModelSelected` so it cannot come back enabled
over a finished recording. The other two `#selector(App.…)` uses in the app were
checked at the same time and are both nil-target `sendAction` calls already.

**The general shape is worth more than the fix**: an item with an
`attributedTitle` cannot look disabled, so it is the one kind of menu item whose
target and validation have to be read rather than trusted to the screen. Every
red item in this app is in that class.

## A search that found something could not say where

Typing `peco` returned the right recording and nothing else: one row, with no
way to tell whether it matched the title or minute 26 of a 38-minute call, or
how many times. `RecordingFilter.apply(to:)` matched `displayTitle ||
transcriptText` and `SidebarViewController.matches` matched `note.title ||
note.body`, and **both returned a `Bool`**. The hit was computed and thrown
away, so the row could only ever say "this one".

`RecordingFilter.search` is `apply`'s work with the ranges kept, and `apply` is
now one line calling it, so there is still one predicate. Three things fell out
of doing it that way rather than by excerpting in a second pass:

- **The excerpt is free.** `storedTurns` re-reads and JSON-decodes `turns.json`
  on every access with no cache, and the search already paid that for every
  recording on every keystroke. A second pass to excerpt would have doubled the
  expensive half of typing.
- **Matching per turn fixed a false positive nobody had noticed.**
  `transcriptText` joins paragraphs with a space, so `budget meeting` matched a
  recording where one word ended turn 3 and the other began turn 4, which nobody
  said. It also has no speaker and no timestamp to attribute a hit to, and those
  are exactly what the row needs.
- **A title-only match gets no excerpt line.** The title is the row's first
  line, so a snippet under it repeats what is directly above, on exactly the
  rows that matched most cheaply. The words in the title are marked instead.

`Excerpt.around` is the first thing here that cuts *around* a match rather than
off the front; `ReferencePopover.snippet` takes no query and `Chat.shorten` is
head-anchored. The match sits in the left third of the window rather than the
middle, because what follows a term is far more often the answer than what
precedes it.

### The count and the page can disagree, in two ways worth knowing

Both arrive as a bar reading "Not found" over a row that promised a match, and
both are correct rather than bugs to chase:

1. A query spanning the `" "` that `transcriptText` joins two turns with matches
   the list and not the page.
2. The list matches `displayTitle`, and the page can only search
   `titleLabel.stringValue`, which is empty on an untitled recording. So
   searching "untitled" lists recordings the page cannot find it in.

The bar opens anyway. One that refuses to appear after a click that said the
word is in there is worse than one that says honestly that it is not on screen.

## Conversations are offered at the foot of a search, not listed in it

`agent.md` records that the conversations are deliberately not a fourth
collection of the library, which is why `ChatNav` has no collection picker. A
search that silently ignores them is still wrong: the word is in there and the
library said nothing.

So the last row of a search is a verb, `Row.chats`, reading "3 conversations
mention "peco"" and entering chat mode with the query carried across.
`ChatNav.search(_:)` fills the field as well as the state, because a list
narrowed by a term the reader cannot see is a history with conversations missing
from it. Both fields sit at (17, 82), 272 by 26 — the measurement in `agent.md`
under "The search field belongs where the list it swaps with keeps its own" — so
the word appears to stay put while the list under it changes.

Three things it has to get right:

- **`shouldSelectRow` is false for it.** It is a way out of the list, not a
  document in it.
- **It is a `SectionHeader`, not a `HoverRow`.** `HoverRow` is a plain `NSView`
  with a target and an action and is invisible to accessibility, which is what
  makes every popover list row in this app untestable. This row has a
  consequence, so it has to be pressable through `AXPress`.
- **Only when the count is above zero, and only with no kind lens on.** A row
  reading "0 conversations" on every search is an advertisement rather than a
  result, and `kind:` is somebody having already said which collection they
  mean.

## The playback highlight erases anything else written on a paragraph

`TurnView.highlight` rebuilds the body from `base` and assigns
`bodyLabel.attributedStringValue` **wholesale**, so a find highlight written
straight onto the label survives until the playhead next crosses a sentence
boundary and then vanishes. Its `guard index != highlighted` early-out means
that can be many seconds later, and only while something is playing: the shape
of bug that gets reported as "sometimes".

There is now one writer. `highlight` and `setFind` both set state and call
`render()`, which is the only place that label's string is assigned. The
playhead's sentence goes on first and the find ranges over it, because a match
inside the sentence being spoken is still a match and is the one the reader
asked for.

**Yellow, not a third alpha of the accent.** The page already spends that colour
twice on one paragraph, 0.07 for the turn and 0.30 for the sentence, and the
comment above `isCurrent` exists to keep those two apart. A third shade would be
a third thing to tell apart at a glance. The current match is `systemOrange`
with fixed black ink, for `Brand.onAccent`'s reason: the fill does not change
between appearances, so the ink on it must not either.

`setFind` guards on equality, which is what makes a blanket loop over every turn
affordable. Measured with `LISTEN_DEBUG=1` on the longest transcript to hand,
156 turns, the worst query anybody can type:

```
find "e"     2546 matches over 156 turns in 2 ms
find "th"     700 matches over 156 turns in 1 ms
find "the"    385 matches over 156 turns in 0 ms
```

So no coalescing timer and no two-character minimum. Both would have been
latency added to hide two milliseconds.

`stopEditing` has to call `render()` too. It clears `highlighted` and leaves the
next playhead tick to repaint, and the find highlight has no tick to wait for:
without it a turn whose sentence was just corrected comes back with its matches
missing until the audio reaches it, which on a paused meeting is never.

## `show` runs on every activation, so closing the bar there closes it constantly

`LibraryWindow.reload()` calls `detail.show(fresh)` on every app activation,
every queue tick and both edges of capture. A find bar closed unconditionally in
`show` therefore shuts under the reader several times a minute.

`recording.id != previous` is the gate, and it is the same test the three lines
around it already make for `endEditingTitle`, `scrollToTop` and `follows`. The
same rule with a different consequence each time, which is why it is worth
naming: **`show` is not only how a selection is answered.**

Across a rebuild the current match is kept by its **address**, not its index.
`renderTurns` throws every `TurnView` away and an edit renumbers every turn
after it, which is the distinction `currentStart` already records against
`currentTurn`.

## The find bar is under the player, and collapsed it is not there at all

Closed, `findTop` and `findHeight` are both 0, which puts the bar's bottom edge
exactly on `playerCard.bottom`. The three views that used to hang off the player
— `scroll`, `live` and `askView` — hang off the bar instead at the same 8, 12
and 8, so **the page with the bar shut is laid out to the point as it was before
the bar existed**. On a page this heavily tuned that is worth more than a tidier
hierarchy: the collapsed state cannot be subtly wrong.

Two placements that do not work, both tried on paper first:

- **The top of the pane.** The window is `.fullSizeContentView` with
  `titlebarAppearsTransparent`, so the toolbar floats over the content and a
  full-width bar up there runs under the ellipsis and the record capsule.
  `titleLabel`'s 38 works only because a title is left-aligned and those items
  are on the right.
- **An overlay.** It covers the top of the transcript, which is where the first
  match usually is, and every `scrollToVisible` below would carry a permanent
  top margin for ever. The obvious fix is unavailable: a content inset is a
  scroll offset and will not hold a view in place, which is why `scroll` already
  runs with `automaticallyAdjustsContentInsets = false`.

This reverses nothing in "the transcript is never filtered": the bar decorates
and scrolls, and `turns`, `sentences` and `turnViews` stay index-aligned.

The `applyFocus` objection is answered rather than ignored. A bar under the
player makes the page breathe, and that was `focusBar`, driven by a click on a
*speaker name* — a gesture that had no business moving the page. Cmd-F means "I
am about to search this page"; it moves once at the open and once at the close.

**`FindBar` owns its own delegate, and must.** `DetailView` is an
`NSTextFieldDelegate` and its `controlTextDidEndEditing` does not check which
field sent it: it renames the recording to `titleLabel.stringValue`
unconditionally, because the title used to be the only field delegating there.
Pointing the find field at the pane renames the meeting to the search string the
moment the field gives up focus.

## `scrollToVisible` moves as little as it can, and the two coordinate systems run opposite ways

Two bugs on one line, and the second was hidden by the first.

**`scrollToVisible` does the smallest scroll that works**, which for a find jump
puts the match flush against an edge. That is right for the playhead, which is
following along and should move the page as little as it can; it is wrong for a
jump somebody asked for. Measured on a 41-minute call: opening on match 1 left
the matched paragraph on the last line of the viewport with the eight turns
before it filling the screen above, so the page looked like it had not moved.

So a find jump computes its own origin, and that is where the second one is.
**The stack is unflipped and the clip view is flipped, and they count opposite
ways.** A turn's frame counts up from the bottom of the document, so turn 0 has
the *highest* y; `contentView.scroll(to:)` wants a point counting down from the
document's top. The distance from the top to a frame's top edge is therefore
`document - frame.maxY`. Using the frame's own y scrolls most of a meeting the
wrong way: measured, opening on the match at 15:51 landed the page at 21:14, six
minutes past it, with the match off the top of the screen.

**Neither symptom is visible to a test that reads the AX tree**, which is the
part worth keeping. Every `TurnView` is in the tree whether or not it is on
screen, so a page that never moved reads exactly like one that moved correctly,
and the counter says "1 of 8" either way. It was found by looking at a
screenshot. `verify_search.sh` now asserts the `find scroll … lead=60` trace
instead, which is the number that changes when the arithmetic is inverted.

`reveal` keeps its `follows` gate and its minimum scroll; `bring` is the
mechanism under it and takes `atTop` for the find path.

`follows` goes false when the bar opens, the rule `applyEdit` already makes:
searching is the reader saying they are reading. **Closing does not put it
back**, and that asymmetry is deliberate rather than an omission — `follows` is
re-armed only by opening a different recording, and re-arming it here would pull
the page away the moment the bar went down. `readingOrigin` needs nothing:
`userScrolled` writes it on every bounds change including programmatic ones.

## A two-line cap does not shorten anything, and the third line lands on the next row

`maximumNumberOfLines = 2` with `.byTruncatingTail` drew **three** lines of an
excerpt in a row whose height is a constant, so the overflow was painted over
the row below and there was no air left inside the card.
`truncatesLastVisibleLine` is the other half: the cap limits what is laid out,
and this is what makes the last laid-out line end in an ellipsis rather than
simply stopping. Both are needed.

The prefix comes out of the excerpt's budget rather than being added on top of
it. `Excerpt.width` is two lines of the row, and the speaker and the timestamp
share those two lines, so adding them made the field's own elision cut the
window instead of the one that keeps the match in view: the tail of every
excerpt was lost.

## The padding inside a row's card is stated, not left to the centring

`RecordingCell` centres its content on a layout guide, which is what let the row
grow from 52 to 86 points for a result without anything else moving. Centring
alone kept the rows honest only while the content was two short lines: fill the
height and the centre stops moving, and the padding silently goes to zero.
`HoverRowView` draws its card at `bounds.insetBy(dy: 2)`, so text near the row's
edge sits against the card's corner.

Two inequalities against the row's own edges at 10, with the centring dropped to
`.defaultHigh` so the pair can never be unsatisfiable. They cost nothing on a
row with room and bite on the one that has not. Reported by a reader looking at
it, not by anything here.

**Variable row heights are cheap in this list, which reverses `NoteCell`'s
note.** That note gives the flat 52 as a reason not to put tags on a row, and
three things make the third line affordable where pills were not: `heightOfRow`
is already a per-row function, nothing in this app works out where a row is by
multiplying, and it is three constants rather than N, so nothing has to measure
any text to answer.
