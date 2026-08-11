# AppKit traps that are not Listen's fault

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

Things AppKit does that no documentation warns about. These generalise past this app: popovers, menus, the missing nib, focus and Cmd-Q.

## `NSPopover` and the row of chips

Three rules, all learned by measurement, all invisible from the code:

1. **A popover closes when its positioning view leaves the window.** The chips
   are rebuilt by `configure` on every reload of the pane, so a popover anchored
   to a chip is anchored to something with a lifetime shorter than itself.
   `SpeakerChips` therefore hands out the *row* as the anchor and the chip's
   rectangle within it.
2. **A popover that does not fit is closed, not moved.** The chips sit near the
   top of the window, so `preferredEdge: .maxY` asks for 362 points of popover
   in the hundred points between the row and the menu bar. It opened and closed
   inside the same `show(relativeTo:)` call, reporting `isShown == false`
   immediately afterwards with a close reason of "standard" and no other
   symptom. `.minY` is downward in an unflipped view, which is where the room
   is.
3. **A view that has *already* left the window does not close the popover, it
   crashes the app.** Rule 1 is the polite half of this and reads as though it
   were the whole of it. `showRelativeToRect:ofView:preferredEdge:` raises
   `NSInvalidArgumentException`, "view has no window. You must supply a view in
   a window", and nothing catches it.

It is also shown on the next runloop turn rather than inline, because a popover
put up from inside a control's own action arrives while the mouse event is still
being dispatched.

### Replacing a scroll view's clip view resets `drawsBackground`

Every popover here puts its list in an `NSScrollView` with a
`TopAlignedClipView`, and whether that list sits on the popover's material or on
an opaque grey well came down to the order of two lines. `NSScrollView`'s setter
reaches through to the clip view it holds **at that moment**, so

```swift
scroll.drawsBackground = false
scroll.contentView = TopAlignedClipView()   // a fresh one, defaulting to true
```

hands back a clip view that paints `.controlBackgroundColor` over the card.
`DetailView` and `PeoplePane` assign the clip view first and were right by
accident; `SpeakerPicker` and `PersonPopover` were the other way round and both
drew the well. It is invisible until the list is short enough to see through,
which is why it shipped.

Answered in `TopAlignedClipView` rather than at the four call sites: every
caller sets `drawsBackground = false` on its scroll view, so none of them wants
one, and overriding the property to `false` makes the ordering stop mattering.

### No window is the only thing that raises

Worth knowing exactly, because the natural fix for rule 3 is to start
sanity-checking the rectangle too, and there is nothing there to check. Measured
against AppKit directly, one popover per row:

| positioning view | result |
|---|---|
| in a window, own bounds | opens |
| never in a window, or removed from one | **raises** |
| hidden | opens, `isShown == false` |
| zero height, which is a collapsed chips row | opens, `isShown == false` |
| rect 4000 points outside its bounds | opens, `isShown == false` |
| `NSZeroRect` | opens, documented to mean the view's bounds |

So a rect that is wrong costs a popover nobody sees, and an anchor that is gone
costs the process.

### The pane is the anchor, and the rect is taken before the edit is committed

Shipped in 0.2.0 and reported from a real session: rename a recording, click a
speaker in the transcript, `SIGABRT`. Reproduced against the same build,
identical frames, `-[NSPopover showRelativeToRect:ofView:preferredEdge:] + 244`
under `_dispatch_call_block_and_release`, which is the deferred block above.

Every speaker click calls `endEditing()` first, because a control swallows its
own click and the title field would otherwise keep the caret. That commits the
title, a committed title reloads, and a reload runs `renderTurns`, which empties
the transcript stack. So one line after `endEditing()` the view that was clicked
is out of the hierarchy, and it is *also* too late to call `convert(_:from:)` on
it: with no common ancestor left, the rectangle it returns is meaningless and
nothing reports that either.

`DetailView.editSpeaker` is therefore the one funnel for all three callers, and
it does the three steps in the only order that works: take the rect, then end
the edit, then point the popover at the pane, which is on screen for as long as
the transcript is. `PersonPopover.show` and `SpeakerPicker.show` additionally
refuse to show on an anchor with no window, with a `LISTEN_DEBUG` trace, so the
next caller to get this wrong loses a popover instead of the app.

Verified by driving the real window: the crash sequence now opens the contact
card, the unnamed-speaker picker and the chip's card, and the guard has not
fired once.

**Do not verify this with System Events.** `first application process whose
unix id is N` returned a *different* Listen when several were running, so the
first three attempts at this were inspecting the wrong process and reporting the
wrong library's contents. `AXUIElementCreateApplication(pid)` cannot pick the
wrong app.

## An `NSMenuToolbarItem` eats the first item of its menu

A pull-down takes item 0 as the button's own title and never draws it, and both
ellipsis menus in this window were built without knowing that. Measured on the
shipped 0.1.0 build by opening each one and reading it off the screen:

| menu | built | shown |
|---|---|---|
| recording, one selected | Export…, sep, Transcribe Again, Rename…, sep, Show in Finder, sep, Delete | Transcribe Again, Rename…, Show in Finder, Delete |
| recording, none selected | No recording selected | *nothing at all* |
| person | placeholder, Edit, Merge…, sep, Delete | Edit, Merge…, Delete |

So Export was missing for as long as the toolbar menu has existed, and the empty
case was worse than missing: one disabled item is the whole menu, AppKit does not
put up an empty menu, and pressing the button therefore did nothing and reported
nothing. `PersonPane` had already paid for this once ("Edit Contact was eaten and
the menu opened on Merge"), which is why its `menuNeedsUpdate` starts with a bare
`NSMenuItem()`.

`LibraryWindow` now does the same, but **only for the toolbar's menu**. The
sidebar's right-click menu shares that delegate and is an ordinary contextual
menu, which shows every item it is handed, blank one included. Hence
`recordingActionsMenu` is built once and kept: the identity check is what tells
the two callers apart.

## The status menu is Speak's, refilled in place

`App.refreshMenu` is a port of Speak's `refreshMenu`, down to the order: the app's
name with the mascot at 15 points, the verbs, whatever is wrong, the library, a
Recent list, then Settings, Check for Updates, About and Quit. The row that names
the app exists for Speak's reason and it is stronger here, because Listen's icon
is one of twenty in a menu bar and the only other place the app said its own name
was `About Listen`, eight items down.

Four things about it are load-bearing.

**One `NSMenu` for the life of the process.** `menuWillOpen` calls `refreshMenu`,
which does `removeAllItems` and refills; handing the status item a *new* menu from
that callback would swap the menu out from under the one being displayed. This is
also why `rebuildMenu` and `refreshMenu` are two functions. `rebuildMenu` follows
capture everywhere else it shows: the icon, the tooltip, the floating panel and
`LibraryWindow.recordingChanged()`, which rebuilds the sidebar and the toolbar.
None of that is something opening a menu asked for.

**The clock is only right because of `menuWillOpen`.** `Capture.onChange` fires on
the edges of capture and not per second, so `Recording, 0:00` drawn once at the
start stayed 0:00 for the length of the meeting. The library count and the Recent
list are re-read there for the same reason.

**`autoenablesItems` is off, and that is deliberate.** Left on, an item is enabled
whenever its target responds to its action, which silently ignores the one line in
this menu that says otherwise: Sparkle disables its own check while one is running,
and `Updater` has no `validateMenuItem` for AppKit to ask. So enablement is stated,
and the rows that only report something go through `info()`, which sets **both** a
nil action and `isEnabled = false`. Measured against the built app either way: the
rendering is identical, so the dimmed rows are not evidence that the old form was
doing the work.

**A recent row carries the recording's id in `representedObject`, not its index.**
The menu is rebuilt on every open and a recording can arrive or be deleted between
two of them, so an index taken from the menu drawn last time names a different
meeting by the time it is clicked. Speak's `copyRecent` keys on `tag` and is right
to: its five entries are re-read from the same file in the same handler.

Two differences from Speak, both because a meeting is not a dictation:

1. **Clicking a recent row opens the recording**, where Speak copies the text. A
   dictation *is* its text; a meeting is an hour of audio, a transcript and a set
   of speakers, and there is nothing useful to put on a pasteboard.
2. **The stamp is a time only for today**, and the date otherwise. Speak's history
   is the last five things you dictated, all minutes old; a library spans months,
   and `15:14` on a recording from Tuesday is a lie nothing on the row corrects.
   The cost is that the titles no longer line up in a column, which is what a tab
   stop in an `attributedTitle` would fix and is not worth an attributed string
   whose highlight behaviour would then need checking.

The recording in progress is deliberately **not** in Recent. It is the two rows at
the top of the same menu, and listing it twice puts one meeting under two verbs.

`LibraryWindow.open(recording:note:)` gained `activate` and `makeKeyAndOrderFront`
for this. Its first callers were note links inside a window that was already key,
so it built the window without ever showing it; from the menu bar that is a click
that appears to do nothing. Verified by closing the window through its accessibility
close button, pressing the first Recent row, and finding the library up with that
recording selected and its transcript rendered.

## Listen is not `LSUIElement`, and Speak is

This is the one place the Speak template was deliberately reversed. Speak is a
menu bar utility with no primary window, so hiding it from the Dock is right.
Listen's main surface is a window people read transcripts in for minutes at a
time, and an app you cannot reach with Cmd-Tab or the Dock is an app you cannot
get back to once its window is behind a browser.

So: `.regular` activation policy, no `LSUIElement`, menu bar item kept for
start and stop, `applicationShouldTerminateAfterLastWindowClosed` returns false
because a recording may still be running, and `applicationShouldHandleReopen`
brings the window back.

The onboarding rule this reverses one reason for still holds. Windows must
float and re-activate after each permission prompt: a window behind a system
dialog is unrecoverable either way.

## A text field does not stop editing because you clicked away

Clicking the title, then clicking the transcript, left the caret blinking in the
heading. Nothing was broken: `NSView` does not accept first responder, so a
click on a plain view goes nowhere and the field keeps focus. Only a control
takes it away, which is why clicking the sidebar table always worked and
everything else did not.

`DetailView.mouseDown` ends editing, and catches every click that no subview
claimed, because `NSView.mouseDown` forwards up the responder chain. Clicks that
*are* claimed do not arrive there, so the play button, the waveform, a turn and
a speaker name each call `endEditingTitle()` themselves.

## `NSAttributedString(markdown:)` parses the structure and then throws it away

Handed a whole document it returns the text with inline emphasis applied and
nothing else: headings come back as plain paragraphs at body size, list items
lose their bullets, and a table's cells run together. A note whose headings and
bullets are gone is *less* readable than the raw file, and the raw file is what
is on disk, so rendering has to beat showing the source or it is not worth
doing.

`MarkdownText` therefore splits the job. Blocks are handled here, line by line,
and every line's inline markup goes through Foundation with
`.inlineOnlyPreservingWhitespace`, which is exactly what that option is for.
Bold, italic, code and links come back correct with no second parser to be wrong
in its own way, as an `.inlinePresentationIntent` attribute rather than as fonts,
so the caller's font is applied first and the traits are added on top. That is
what makes a bold word inside a heading a bold heading.

Three things it got wrong first, all visible only against a real note:

1. **A paragraph runs to the next blank line**, not to the end of the source
   line. Everything that writes these notes hard-wraps its prose, and one
   sentence rendered as two half-sentences with a gap down the middle.
2. **A list needs a hanging indent.** Without `headIndent` the second line of an
   item starts under the marker and a list of two-line items stops looking like
   a list.
3. **A numbered item keeps the number it was written with.** Counting them here
   would mean the file and the pane disagree about which one is item 3, and the
   file is editable in any editor.

Tables are padded monospaced text rather than tab stops, because the column
widths are known here and the pane's width is not: a tab stop set from a guess
comes apart when somebody drags the divider.

## An app with no nib has no menu bar, and it is not obvious

Listen builds its own `NSMenu` in `MainMenu.install()`. Without it there is no
menu bar at all, and the gap hides because the window looks finished: what is
actually missing is every standard keystroke. Cmd-Q does not quit, and Cmd-A,
Cmd-C and Cmd-V do nothing in any text field, because those are implemented by
menu items with key equivalents rather than by the fields. This surfaced as
"renaming a recording is unusable", which is several steps away from the cause.

The Edit menu items target `nil` on purpose, so they travel the responder chain
and land on whatever has focus.

### An app with no nib has no key view loop either, and that one is quieter

The same absence, one layer down, and it took longer to notice because nothing
looks broken. AppKit builds the Tab order from a nib; every view here is built
in code, so `nextKeyView` is nil everywhere and `nextValidKeyView` finds
nothing. Tab does not beep, does not move and does not report anything: the
caret simply stays where it is.

Reported against the person editor, which is the worst place for it, because its
first two fields are a first name and a last name **side by side** and typing
one then reaching for Tab is what anybody does. `PeoplePane.renderEditor` and
`PersonPopover.buildEditor` now state the chain, first to last to email to
notes, closing back to the first so Shift-Tab works too. Verified by reading
`AXFocusedUIElement` after each synthesised Tab: `Edgar`, then the empty
surname, then email, then the notes text area.

`notes` is an `NSTextView` and keeps Tab for itself, inserting a tab the way a
multi-line field is supposed to. It is last in the order for that reason as much
as for its place on screen.

Worth knowing for the next form: this is not specific to these two panes. Any
programmatically built stack of fields in this app has the same gap until
somebody says otherwise.

## Cmd-Q is intercepted ahead of the menu, not rebound in it

`QuitConfirm` asks once before quitting, ported from Anarlog because Cmd-Q sits
next to Cmd-W and Cmd-Tab and the cost of hitting it by accident here is a
meeting that stops recording mid-sentence.

It works with a **local event monitor**, which runs before `NSApplication`
dispatches the event and therefore before the main menu matches its key
equivalents. Returning nil means the Quit item never sees the keystroke, so
`MainMenu` needs no change and there is no second Quit action to keep in
agreement with the first. Nothing else is ever swallowed: only Command and Q
with no other modifier held.

Three consequences, all measured on the running app with `LISTEN_DEBUG=1`,
which traces the state machine because an event monitor otherwise leaves nothing
behind to inspect:

1. **The first keydown is swallowed, so the matching keyup may never arrive.**
   The state can still be `held` when the second press lands, so a second press
   confirms from either state rather than only from `armed`.
2. **The status bar item's Quit is not intercepted.** Menu tracking runs its own
   event loop and does not go through `sendEvent`, so Cmd-Q with that menu open
   quits at once, as does clicking either Quit item. That is deliberate:
   reaching for a menu item is already a decision, and it means there is always
   an unconfirmed way out, so no hidden override keystroke is needed.
3. **Quitting still goes through `applicationWillTerminate`**, which stops
   capture, so a confirmed quit mid-meeting finalises the WAV headers and leaves
   the recording in staging for `adoptStaged()` to promote at the next launch.
   The prompt says so on its second line rather than leaving it to be found out.

Synthesised keystrokes are a flaky way to test this: two `System Events`
keystrokes 0.4 s apart delivered only one press on the first attempt, which
looks exactly like the confirm step not working. The trace is what tells the two
apart.

## The sidebar width fought the split view

The first library window was a bare `NSSplitView` with
`widthAnchor` constraints on both sides. Dragging the divider snapped straight
back: the constraints and the split view were both trying to own the same
number and the constraints won on the next layout pass.

`NSSplitViewController` with `minimumThickness` and `maximumThickness` owns it
properly, and `DetailView` no longer carries a width constraint of its own.

Two things are easy to get backwards after that:

1. **Holding priority.** The sidebar's has to be *higher* than the content
   pane's, so resizing the window moves the right-hand edge. The default is the
   other way round, which rewrites the saved width on every window resize and
   looks exactly like the sidebar refusing to stay put.
2. **Ordering.** Set the window's frame autosave name before the split view's.
   Restoring the frame resizes the window, and a resize redistributes the
   split, so the other order overwrites the divider position with whatever the
   resize produced.

Verified by writing a width of 380 into the autosaved defaults, relaunching and
reading it back.

## `intrinsicContentSize` is four points narrower than the text

An `NSTextField` label reports two different widths and they are not
interchangeable. Measured here, system font at 13 point medium:

| string | `intrinsicContentSize` | `cell.cellSize` |
|---|---|---|
| `Stop` | 29.00 | 32.97 |
| `New Recording` | 94.50 | 98.02 |
| `Stop 1:02:05` | 79.50 | 83.48 |

Four points every time, on every string, and `cellSize` is the one the text is
drawn inside: `sizeToFit` uses it. A label whose frame is set by hand from
`intrinsicContentSize` is therefore two points short at each edge, and clips.

It hides for a long time, because two points off a digit or a stem is two points
of nothing. `RecordButton` carried it invisibly for the whole life of a label
ending in a clock, and the first character to end a string with a round bowl on
its right, the `p` of "Stop", came out cut in half.

Nothing warns about this: both properties return a plausible size and neither is
documented as the drawing width. The rule is that a hand-placed label is sized
from `cellSize`, and the only reason to touch `intrinsicContentSize` is when
Auto Layout is placing the label for you, where AppKit adds the same padding
back itself.

## A typed chevron is not aligned with the text beside it

The drawer's conversation title carried its caret as a character, `"⌄"` appended
to the string, U+2304 DOWN ARROWHEAD. It sits visibly below the words next to
it, for two reasons at once: the glyph is centred on its own em box rather than
on the x-height of the run it lands in, and no system font ships it, so it
arrives from whatever fallback carries it and matches neither the baseline nor
the weight.

An SF Symbol on the button is laid out against the title's own line and inherits
the weight, which is why every other chevron in this app is an image:

```swift
button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "")
button.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
button.imagePosition = .imageTrailing
button.imageHugsTitle = true          // or it is pushed to the button's far edge
```

`imageHugsTitle` puts it against the last letter with nothing between them, so
the title keeps one trailing space. `AnswerTurn`'s disclosure records the other
half of this: two glyphs rather than one rotated, because a rotation under Auto
Layout is only aligned in one of its two states.

## A tool tip is a tracking area, so clearing them all takes it with it

The idiom every hover in this app started from clears the lot and puts one back:

```swift
override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }   // not on a button
    addTrackingArea(NSTrackingArea(rect: bounds, options: […], owner: self))
}
```

`trackingAreas` is not a list of what this class put there. `NSToolTipManager`
installs one per tool tip rect, and `updateTrackingAreas` runs on every geometry
change, so a view that clears the array removes its own tool tip a fraction of a
second after AppKit installed it. `HoverRow` gets away with it because a sidebar
row has no tool tip; the drawer's cross, resize and new-conversation buttons all
have one, and each is the only thing that says what its glyph means.

The fix is to hold your own area and remove it by name, which is what
`HoverButton`, `LinkLine`, `SendButton` and `AnswerTurn.HeaderRow` all do now.

## An attributed title's colour wins over `contentTintColor`

`contentTintColor` colours a borderless button's template image and its plain
`title`. It does nothing to an `attributedTitle`, because that string carries a
`.foregroundColor` of its own and the string wins.

Half the buttons in this app set one, for the reasons `SpeakerPill` and the
drawer's title record: a hand-built title is the only way to control the
paragraph style, the truncation and the trailing glyph. So a hover that only
writes `contentTintColor` lights the chevron and leaves the word beside it grey,
which reads as a rendering bug rather than as a highlight.

`HoverButton` keeps the string as the caller set it and recolours a copy on the
way in, which is also what puts it back. The setter is overridden to capture it,
and the recolour writes through `super`, or the lit copy becomes the one the
button remembers and it never goes quiet again.

## `glyphIndex(for:in:)` answers with the nearest glyph, however far away

Underlining the link under the pointer needs the character at a point, and
`NSLayoutManager` will always name one: the method returns the *nearest* glyph,
with no notion of a miss. The pointer anywhere in the margin beside a line comes
back as the last character of that line, so a centred column of links, which is
exactly what the landing page's recent conversations are, underlines whichever
one the mouse is level with from anywhere on the row.

The bounding rect is what tells being over a letter from being beside one:

```swift
let glyph = manager.glyphIndex(for: inside, in: container)
let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                in: container)
guard rect.contains(inside) else { return nil }
```

The point has to have `textContainerInset` taken off it first, which is the same
correction `AnswerTurn.rect(of:in:)` applies in the other direction when it puts
a popover on a reference number.

The underline itself is a *temporary attribute* on the layout manager, not an
edit to the text storage. The storage is what `LinkLine.intrinsicContentSize`
measures and what a streaming answer is written into, and neither should ever
see a decoration that belongs to the mouse. Temporary attributes do not re-wrap
the text and are dropped when it is replaced.

## A disabled button greys its title, unless the title is attributed

`isEnabled = false` dims a plain `title` for you. It does nothing to an
`attributedTitle`, which is the same rule `contentTintColor` follows above and
for the same reason: the string carries a `.foregroundColor` and the string
wins.

It is invisible until a control both draws its own shape and reports its own
outcome. `AnswerTurn`'s Save as note becomes "Saved" with a checkmark and
disables itself so one answer cannot become two notes, and as a `ChipButton` it
kept full-strength `labelColor` text on a capsule that no longer responded: a
spent control that reads as a live one, which is worse than no confirmation.

`ChipButton` therefore rebuilds its title whenever `isEnabled` changes, at
`labelColor` or `tertiaryLabelColor`. Anything that hand-builds a title has to
answer this question; `SpeakerPill` does not only because nothing ever disables
one.

## A content inset is a scroll offset, and it will not hold a view in place

`NSScrollView.contentInsets` looks like padding and is not. It widens the
scrollable range so the document *can* sit clear of an edge; the clip view then
decides where the document actually is, and it clamps the range away when there
is less content than clip view. An empty text view is always that case.

The notes pane paid for the difference. The note's first line was placed by
`contentInsets = NSEdgeInsets(top: 14, …)` on `notesScroll` plus two points of
`textContainerInset`, and its placeholder, which is a sibling label because
`NSTextView` has none of its own, was pinned honestly at 14 + 2 below the same
scroll view. On an empty note the clip view dropped the 14, so the caret came up
at 2 and the prompt it is supposed to sit on was a line below it: the two are
looked at together on exactly the one screen where they disagree.

Measured on the built app over a scratch `LISTEN_LIBRARY`, through
`AXUIElementCreateApplication(pid)`: with the inset gone and the 14 points moved
into the constraint above `notesScroll`, the text view reports y=242 and the
placeholder label y=243, and a line typed into the note lands on the pixel row
the placeholder occupied. The pane's geometry is unchanged, because the box
starts 14 lower and `sizeNotes` no longer adds 14 to it, so `notesFloorHeight`
and `notesCeilingHeight` came down by 14 with it.

The rule that generalises: use a content inset for what a scroll view should be
able to reach, never for where something is. Anything a second view has to line
up against belongs in a constraint, where nothing can reclaim it.

## A leading image is laid out at the button's edge, not beside its title

`ChipButton` sizes its own capsule, so a glyph added later has padding reserved
for it: the width is the title, plus the image, plus one gap, plus 13 either
side. `AnswerTurn` sets a checkmark on the Save chip the moment it is pressed,
which is the whole of how that press is confirmed, and it came out hard against
the rounded left edge with a gap the width of the padding between it and the
word.

The reserved space was spent in the wrong place. `NSButtonCell` with
`.imageLeading` puts the image against the leading edge of the frame and lays
the title out in what is left, and the title's own paragraph style is centred, so
the two drifted to opposite ends of a capsule that was exactly wide enough for
them side by side.

`imageHugsTitle = true` is the whole fix, and it is the second time this app has
paid for it: `DetailWithComposer.titleButton` records the same behaviour for a
*trailing* chevron, which sat at the far right of a button wider than its text.
Set in `ChipButton.init` rather than at the two call sites, so any chip that ever
gains a glyph gets it.

## An `NSToolbarItem` lays out its own image and title, and has no gap to give

An item with both `image` and `title` draws them side by side in an `.iconOnly`
toolbar, which is how "History" and "Chats" get a word next to a clock rather
than under it. There is no spacing property: no `imageHugsTitle`, no insets, and
setting the item's `view` to get them means building the button and its glass
capsule by hand.

The clock came out against the C of "Chats". The gap is a leading space in the
title, `" Chats"`, which is the same one-character shape as the trailing space
`DetailWithComposer.titleButton` puts before its chevron, and for the same
reason: the control lays itself out and the only thing left to say is what the
string is.
