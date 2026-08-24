# Recording the demo clips

What `docs/index.html` expects, and what to point SmoothCapture at to get it.

Nothing here needs an edit to the page. Every media frame carries a
`data-shot="<name>"`, and the page looks for `docs/shots/<name>.mp4` and
`docs/shots/<name>.jpg`. Drop a file in, push, and that frame fills itself in.
Record them one at a time and ship as you go.

Seven of the eight live inside the feature switcher, which shows one at a time
and moves on by itself every nine seconds. So a clip is seen for **nine seconds
at most** unless somebody stops the rotation, which is the strongest argument
for keeping them short and for putting the thing being demonstrated in the
first three.

## The set

Build the demo library first. It writes invented people, invented companies and
speech synthesised with `say`, so nothing published anywhere is a recording of
anybody:

```sh
./make_demo_library.sh
LISTEN_LIBRARY=/tmp/listen-demo LISTEN_DEMO_NAME=Alex \
  Listen.app/Contents/MacOS/Listen
```

A Finder launch inherits no shell environment, so it has to start from a
terminal or it opens your real library on camera.

It contains five meetings, and the copy on the page is written against them:

| Recording | With | App | What is in it |
|---|---|---|---|
| Weekly with Priya | Priya Raman | Chrome | onboarding 44% → 61%, trial 14 → 21 days |
| Design review, mobile | Tomas Lindqvist | Zoom | the filter above the list rather than in it |
| Kickoff: Northwind migration | Aisha Bello | Teams | nine weeks, parallel run, cut over on a Friday |
| Catch-up with Priya | Priya Raman | Chrome | support load fell after the trial change |
| Interview: staff engineer | Marcus Whitfield | FaceTime | a search index nobody needed |

Two notes of your own, and two an agent wrote: **What changed with onboarding**
spans the two Priya calls, **Northwind, the plan as it stands** is about the
kickoff.

The demo library has **no tags**, and the page claims tags exist. Add a couple
before shooting the notes clip:

```sh
export LISTEN_LIBRARY=/tmp/listen-demo
listen tags add <weekly-id> "onboarding"
listen tags add <catchup-id> "onboarding"
listen tags add <kickoff-id> "northwind"
```

### Before the camera rolls

- Window at **1600 × 1000**, which is the 16:10 the empty frames are cut for.
  Same size for every clip, so nothing jumps as the switcher moves on.
- **Dark appearance.** The site is on paper now, and the instinct is to match
  it, but the two stills already up there are dark-appearance Listen and they
  read well: the frame carries a shadow, so a dark window on paper looks like a
  window on a desk rather than a hole in the page. Consistency across the eight
  clips matters more than agreeing with the background, and a half-dark,
  half-light set would look like a mistake.
- Hide anything real: Notification Centre off, a clean menu bar, no Dock
  badges, no second monitor in frame.
- Point the pointer at what you are talking about and then **stop moving it**.
  A cursor drifting under a loop reads as a video that has not finished.

## The loops

Eight silent clips. They autoplay muted, loop for ever and have no controls, so
they are glanced at rather than watched. That decides everything about them:

- **8 to 18 seconds.** Long enough for one action, short enough that the loop
  point comes round before anybody has looked away.
- **One idea each.** The copy beside a clip already says what it means, so the
  clip only has to show it happening.
- **Start and end on the same frame** wherever you can, so the loop does not
  snap.
- **No cursor at the first and last frame**, for the same reason.
- **No audio track at all.** It is muted anyway, and stripping it saves weight.
- Zooms are worth it here: the thing being shown is often one row or one popover
  in a large window, and a 1600-wide frame reduced to a column on the page makes
  a name chip about eleven pixels tall.

Three frames already carry a still from the current site, so those sections work
today and the clip is an upgrade rather than a gap. The other five show a
labelled placeholder until you record them.

### 1. `record.mp4` · 14s · has no still yet

The menu bar, start to finish.

1. Menu bar icon, click. (2s)
2. Press **Start**. The icon changes to the recording state. (2s)
3. Meters moving, the panel showing the clock climbing. (5s)
4. **Stop**, and the keep-or-discard question appears. (3s)
5. **Keep**. The recording lands in the sidebar. (2s)

The point is that the whole thing happens in the menu bar and the question
comes afterwards. Do not open the main window.

### 2. `playback.mp4` · 14s · currently `playback.gif`

Open **Weekly with Priya**. Play, and let the sentence highlight run for a few
seconds so it is clearly following the audio. Then drag the playhead across the
waveform to a later point and let it carry on. Finish by clicking a turn further
down, which jumps the playhead to it.

Zoom on the transcript for the highlight, and pull back for the scrub.

### 3. `speakers.mp4` · 16s · has no still yet

The one that carries the most weight on the page, because it is the feature a
cloud product cannot copy.

**It needs preparing.** The demo library arrives with every speaker already
named, so there is nothing to name on camera. Put Priya back to a letter in the
later of her two calls, and leave her named in the earlier one, which is what
gives the voice bank a voiceprint to recognise her by:

```sh
export LISTEN_LIBRARY=/tmp/listen-demo
listen list                                    # to get the ids
listen label <catchup-id> "Priya Raman" --unname
listen show <catchup-id> | head               # confirm she is a letter now
```

`--unname` is per recording, and the voiceprint goes to the letter with her, so
**Weekly with Priya** is untouched and the bank still knows the voice from it.

Then, on camera:

1. Open **Weekly with Priya**. Her name is on her turns already. This is the
   "named once" half, and it needs no interaction, just a beat. (3s)
2. Open **Catch-up with Priya**, three weeks later. She is `Speaker A`. (2s)
3. Click the name, choose **Who Is This?**. The picker opens with **Priya
   Raman** offered from the voice bank. Pause long enough to read it. (5s)
4. Pick her. Every turn of hers renames at once. (4s)

That is the whole argument: the second meeting already knows. Do not narrate
it, and do not speed up the pause on the picker, because the suggestion is the
thing being shown.

### 4. `ask.mp4` · 18s · has no still yet

Point Ask at Ollama first, so nothing on camera goes anywhere.

1. Type into the composer: **what did we decide about the trial length?** (4s)
2. The answer streams in with numbered references on the claims. (6s)
3. Click a reference. The card opens showing the recording behind it. (4s)
4. **Save as note**. The button says Saved. (4s)

If the model is slow, cut the waiting rather than speeding it up: a sped-up
answer misrepresents how long it takes.

### 5. `notes.mp4` · 12s · currently `notes.gif`

Two halves, and the cut between them is the idea.

1. A recording is running. Click **Notes**, type "we should upsell them" into
   the cursor that is already there. (6s)
2. Cut to the Notes list, open **What changed with onboarding**, and show it
   naming two meetings. Click one, and it opens. (6s)

### 6. `dictate.mp4` · 12s · has no still yet

Leave Listen entirely. Open Mail, or a comment in an editor.

1. Cursor in an empty field. Press **fn + left shift**. The pill appears. (3s)
2. Speak a sentence with a name in it that the dictionary fixes. (5s)
3. Press it again. The text lands where the cursor is. (4s)

Show a real app that is not Listen. The point is that it types anywhere.

### 7. `sync.mp4` · 14s · has no still yet

Needs two Macs in frame, or one screen and a second recorded separately and cut
together.

1. **Settings, Sync**: the device roster, each row saying what it keeps and
   holds. **Keep audio** on. (6s)
2. Rename a speaker, or correct a sentence, on Mac one. (3s)
3. The same change on Mac two. (5s)

Do not show the key. Showing a real sealing key on a public page is a mistake
that cannot be taken back, and the copy already says it can be shown.

### 8. `hero.mp4` · the film, not a loop

This one is different: the page gives it a play button, its own sound and real
controls, because it is watched rather than glanced at. It is also the video for
the README, Product Hunt and social, so it is worth the most work.

**Two minutes, narrated.** A rough spine, and the order matters more than the
timings:

| | Beat | Says |
|---|---|---|
| 0:00 | The menu bar, Start, a call already going | It starts where you are, not in another app |
| 0:15 | Stop, keep, the transcript arriving in seconds | It is written up before you have moved |
| 0:30 | Names appearing on turns, then a second meeting knowing the same voice | It learns who people are |
| 0:50 | A question, an answer, a citation clicked open | You can ask it, and check it |
| 1:15 | fn + left shift in another app, words landing | It types for you too |
| 1:30 | Settings, Sync: two devices, sealed | Your library, everywhere you are |
| 1:40 | The Network tab, or Little Snitch, showing nothing going out | The claim, demonstrated rather than stated |
| 1:50 | Icon, name, download line | |

The last beat before the card is the one worth planning. Every competitor can
film the first five; only this one can film the sixth, and a page that says
"nothing is uploaded" is worth less than eight seconds of showing it.

Keep the narration under the visuals rather than over them, and let the meters,
the streaming answer and the cursor do the timing. If a beat needs a sentence to
explain it, the beat is wrong.

## Exporting

**Loops**, from SmoothCapture:

- MP4, H.264, **1600 × 1000**, 30 fps.
- **No audio track.**
- Aim under **2 MB** each. These autoplay on every visit, and eight of them is
  the whole page's weight.
- Web-optimised, so playback starts before the file has finished arriving. In
  ffmpeg terms that is `-movflags +faststart`; SmoothCapture's MP4 export does
  it already.

**The hero**: MP4, H.264, 1920 × 1200 or 2560 × 1600, with audio, under 20 MB.

**Posters** are optional and cheap. Export one frame of each clip as
`docs/shots/<name>.jpg`, about 200 KB. The page uses it as the video's poster,
and as the still for anybody whose browser will not play video at all. Without
one, an unrecorded frame shows a placeholder naming the missing file.

**Filenames are the wiring.** `docs/shots/record.mp4` and nothing else. A
mistyped name is a frame that silently keeps its placeholder.

## Where the page gets it from

`docs/index.html`, in the script at the foot, and the rules it follows:

- A frame keeps its still until a clip has actually decoded, so a missing or
  broken file changes nothing on screen.
- **A clip is fetched the first time its tab is opened, not on load.** Seven
  clips on one page, one of them visible, so fetching them all up front would
  spend the whole page's weight on six nobody asked for.
- A clip stops decoding when its tab is closed, and starts again when it is
  reopened.
- `prefers-reduced-motion: reduce` stops the loops loading at all, stops the
  rotation, and leaves the stills.
- The hero is outside the switcher and fetches metadata only, until somebody
  presses play.
- No JavaScript at all leaves the page as one section per feature, stacked,
  with every still in place and no tab list. That is the shape the document
  actually ships in; the switcher is folded together by the script.

Once every clip is recorded, the stills currently in the page
(`screenshot.png`, `playback.gif`, `notes-screenshot.png`) are still worth
keeping: they are the poster frames and the no-video fallback.

## Order of work

1. `speakers.mp4`. The strongest claim and the one with no still today.
2. `ask.mp4`. Second strongest, also no still.
3. `record.mp4`. Cheapest to shoot, opens the page.
4. `hero.mp4`. Needs the others shot first anyway, because it is made of them.
5. `dictate.mp4`, `sync.mp4`, then the two upgrades over the existing GIFs.
