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
and re-positions it because the panel is pinned to the right edge of the screen.
Once per digit, not twice a second.

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
   library you are looking at; settings is configuring the app. It keeps the
   gear at the bottom left.
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
5. **Every list needs the Settings row, not just the recordings one.** It was
   the only list with a bottom row, because People was entered from the toolbar
   and left by a back row. Peers behind one control, a gear in one of them means
   being in People or Notes is being somewhere with no visible way to Settings.
   Found by looking for it and it not being there. `sidebarSettingsRow` builds
   the row, the hairline above it and its constraints once for all three.
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
