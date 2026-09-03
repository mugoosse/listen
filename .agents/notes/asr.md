# Transcription: the chunk loop, progress, the model and the queue

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

How audio becomes a transcript. Read this before touching `ASR`, `Chunking`, `Pipeline`, `Queue`, `TranscribingView` or anything about which model runs.

## mlx-audio does not expose word timings, only sentences

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

## The chunk loop is Listen's, and it cuts at pauses

`ASR.transcribe` cuts the track up itself and hands mlx-audio one piece at a
time with `chunkDuration: 0`. `Chunking.pieces` chooses the boundaries: a
nominal one every `chunkSeconds`, then slid **backwards** by up to ten seconds
to the quietest 200 ms window it can find there.

This replaced letting `ParakeetModel.generate` chunk internally, and it bought
three things that could not be had separately.

**One word was corrupted at every seam.** Originally measured on synthesised
speech numbering 60 sentences, so every word is checkable: at `LISTEN_CHUNK=120`
sentence 56 came back as "number 50", and at 60 both 29 and 55 went. The
corrupted segment was short, 1.2 s against about 2.2 s for its neighbours, so
the tail of the word straddling the boundary was being dropped rather than
mistranscribed. mlx-audio chunks with a 2 second overlap and merges token
sequences on the longest contiguous match, and that overlap is not enough to
protect a word sitting on the boundary. A cut inside a pause has no word on it
to lose, so the pieces need no overlap and their transcripts need no merge:
they are concatenated with each piece's start added to its times.

Re-measured against the shipped 0.5.0 build, 300 numbered sentences (803 s),
both at `LISTEN_CHUNK=120` so the only difference is where the cuts land:

| build | sentences | result |
|---|---|---|
| 0.5.0, fixed offsets | 300/300 | 56 missing, 50 twice |
| this one, cut at pauses | 300/300 | nothing missing, nothing duplicated |

Note the rate: 6 seams produced **one** corruption, not six, so the original
"exactly one per seam" was a small sample. The direction is what matters.

**It is about twice as fast**, because the reason for a long chunk went away.
See `ASR.chunkSeconds`: decode cost is strongly super-linear in chunk length,
600 s was chosen only to have fewer seams, and once a seam is free the argument
collapses. Interleaved three times against 0.5.0 on the same 3643 s track, this
Mac: 60.3/27.6, 56.9/28.5, 56.5/29.4 seconds. Two times, consistently.

**There is somewhere to report from.** `generate` returns nothing until the
whole file is done, so before this the only progress a job could report was
which of three stages it was in. Now it is one callback per piece, which is 30
an hour per track. That is the whole of `TranscriptionProgress`, the sidebar
row's percentage and the picture in the pane.

Two things about the boundaries are load-bearing:

1. **Backwards only, never forwards**, so a piece can never be longer than the
   chunk length. The chunk length is chosen against a memory ceiling, and a rule
   that could overshoot is one that occasionally asks for more than the machine
   was judged able to give.
2. **A cut that finds no pause is counted, not hidden.** `Piece.quiet` is false
   when the quietest window in the search range is still within 20 dB of the
   track's speech level, `listen transcribe` prints the count every run, and
   `Pipeline` logs it per track. Such a cut behaves exactly like one of the old
   seams. The whole case for this design is that the number is zero on ordinary
   speech, and a case nobody can check is not one. Measured: **0 hard cuts** over
   32 pieces on each track of a real hour-long two-person call, and 0 over 8
   pieces of synthesised speech.

Plain RMS, not the `MLXAudioVAD` mlx-audio ships. This is not the general
speech-versus-noise problem a VAD solves: the search window is ten seconds of a
conversation and all that is wanted is the quietest moment in it. A VAD would be
another model to download on first run, which is a poor trade for a boundary
that only has to avoid landing inside a word.

### One chunk length for every Mac, and it is the short one

`ASR.chunkSeconds` was 600 above 12 GB of installed memory and 120 at or below
it, so the same file transcribed on two Macs had a different number of seams and
therefore a different number of corrupted words. That whole trade is gone. It is
120 everywhere, and the three arguments all point the same way now: 120 s is
over twice as fast as 600 s, it peaks far below the 3.28 GB that made 600 s
unaffordable on an 8 GB M1 Air, and it makes an hour 30 progress units per track
rather than 6.

`LISTEN_CHUNK` still overrides it, and still exists for measurement rather than
for users. `listen transcribe` now reports the pieces and the hard cuts rather
than the chunk length and an implied seam count, because with the boundaries
moving those had stopped being the same statement.

## Progress is counted, and there is no estimate anywhere

`TranscriptionProgress` carries pieces decoded over pieces to decode, per track.
There is deliberately **no time remaining**, and the reason is worth keeping:
the only way to show one before the first piece lands is to carry a throughput
figure measured somewhere else, and a figure measured on this 128 GB machine is
a promise an 8 GB M1 Air cannot keep. A machine's own speed shows up as how fast
the bar moves, which is the honest form of the same information.

`overall` averages the two passes rather than weighting them, because they are
the same model over two tracks of the same length and there is nothing to
weight. Diarization reports no fraction at all, so the bar **holds at one half**
while it runs, with the message saying why. That is about 7 seconds in 57 on the
hour-long recording this was measured against, and a bar that visibly waits next
to a sentence explaining the wait beats one that invents movement to cover it.

Whether there are two lanes is settled **before the model loads**, from whether
there is a mic track with speech in it. A picture that grows a second half when
the first pass ends reads as the first half having been wrong. That is also why
`Pipeline.isSilent` moved up: an untouched microphone would otherwise draw a
lane for the user that never fills.

### The one lane is not always the everyone track

`split == false` covers two different single-track jobs, and they report into
different fields: an import's mixed track fills `everyone`, while a room
recording with a silent (or absent) system track transcribes only the mic and
fills `you`. `TranscriptionProgress.overall` used to read `everyone` alone
when not split, and `TranscribingView` mirrored `drawnEveryone` into both
halves of the single lane, so for a room recording the percentage, the sidebar
activity bar and the picture all sat at zero for the whole job and the
transcript arrived out of nowhere. Reported from a 48-minute solo room
recording re-transcribed while somebody watched the pane. Both now take
`max(everyone, you)`, which is whichever track is actually running, since the
other stays 0 for the life of the job. `listen transcribe <id>` prints the
same `overall` per piece, which is how the fix was verified without the
window: the room job now logs 0% through 100% instead of 0% throughout.

### A job advancing is not a queue change

`Queue.onProgress` is separate from `Queue.onChange`, and the split is required
rather than tidy. `LibraryWindow.reload` re-shows the selected recording, which
stops playback and puts the playhead back to zero, and it is the right answer to
a recording arriving or finishing. Progress is the same job moving, 60 times a
job now rather than three or four, and sending it down that path would interrupt
anybody listening to one meeting while another transcribes, once per piece. So
progress redraws one sidebar row (`Sidebar.tickRow`, which is `tickLive`
generalised) and sets two numbers on a view already on screen.

### The picture is the meeting, drawn as it is read

`TranscribingView` fills the pane that used to hold one grey sentence. It draws
the recording's own envelope, the same `waveform.json` the scrubber below it
uses, through `Waveform.resample` so the two cannot disagree about a bar.

**Two lanes because there are two tracks**: the upper half is everybody else and
the lower half is you, each filling during its own pass. A single bar would have
had to sweep twice and reset in the middle, which reads as starting over. An
imported recording has one mixed track and gets one lane, because the picture
should say what the job actually is.

Two details are the sort that only show up in use:

1. **The fill eases toward the reported value rather than jumping to it.** A
   piece takes a second or two, so the truth arrives in steps. Easing means the
   drawing always shows *at most* what has been reported: it lags and never
   leads, which is the only direction a progress bar may be wrong in.
2. **The bar at the head pulses, and is the only thing not driven by counted
   work.** It moves in brightness, never in position, so it cannot claim
   progress that has not happened. Without it a busy chunk on a small Mac is two
   seconds of a completely still picture, which people reasonably read as hung.

### The head is a position, and it took three tries to say so

Read and unread meet at the reported fraction and nothing else marks it. Three
earlier versions each put something beside that boundary, and each was worse for
it:

1. **A gradient over the lane rectangle.** It paints the gaps between the bars
   as well as the bars, so a solid blue block sat on top of the waveform and was
   the first thing the eye found in the whole picture.
2. **A band of brightened bars, about 34 points behind the head.** A band is
   read at its middle, so the apparent value sat half a band short of the
   reported one, and what it showed was something sweeping past rather than
   somewhere reached.
3. **A hair line across the full lane height.** Honest about the position, but
   it is a ruled mark through the empty space above and below the bars: it draws
   the eye to a rectangle nothing is in, and it makes the picture read as a
   chart with a cursor on it rather than as a recording being read.

What is left lights the one bar the boundary is crossing, so every mark in the
picture is part of the waveform. The cost is that a head passing through a
silence has only the 1.5 point minimum stub to light, which is the honest
version of "there is nothing here".

The fill is **clipped at the fraction, not filtered bar by bar**. Selecting the
bars whose left edge is behind the head means the colour can only change where a
bar starts, so the boundary moves in whole bars of 3 points and a fill crossing
the pane takes its steps visibly. Clipping cuts the bar the head is standing in,
which costs one rounded corner and buys a boundary as smooth as the number
behind it.

`LISTEN_PANEL=transcribing[:0.6]` puts it on screen on demand, against a real
recording so the envelope is a real one. Same argument as the recording panel's
preview clock: this state lasts under thirty seconds a track here and needs a
meeting to reach, so without it the only way to look at the drawing is to catch
it.

## The microphone is a room or a person, and the pipeline has to ask which

"The mic is the user and the system output is everyone else" is a **remote-call
assumption**, and it held for as long as every recording was a call. A laptop on
the table in a meeting room breaks it in the worst available way: the microphone
carries four people, the system track carries nobody, and the whole meeting is
filed under `Me` with nothing on screen suggesting anything went wrong. Reported
from a 47-minute workshop whose transcript read `speakers: Me`.

So `Pipeline.decideRoom` asks, once, at transcribe time. A person's answer wins
(`metadata.room`, with `room_auto` cleared) and is never re-decided. Otherwise it
is inferred from two facts the folder already holds: nothing was on a call, and
nothing sustained came out of the speakers.

Inferred at transcribe time rather than at capture, where it would be cheaper,
because **neither fact is settled while the recording runs**: the call app can
appear minutes in (`Capture.noteApp`), and how much a track holds is not known
until it has stopped.

Read `appBundleID`, never `metadata.app_bundle_id`. The older half of the library
keeps the identifier in `source`, so the field on its own says "nobody was on a
call" for every recording made before it existed, and each of those becomes a
candidate for being re-read as a room.

### A peak test cannot tell a chime from a conversation

`isSilent` asks whether a track holds any signal at all, which is the right
question for the microphone and the wrong one for this. Measured on that
workshop:

    system.wav  peak 0.364  rms 0.00094     7 of 2828 seconds over 0.01
    mic.wav     peak 1.376  rms 0.01199  2777 of 2828 seconds over 0.01

The system track is an idle Mac with a notification chime in it. Its **peak** is
0.364, which any peak test calls "not silent", and reading that as somebody on
the far end is what decides that the microphone holds one person. The question is
not how loud a track got but how much of the hour it occupied, so
`Pipeline.signalSeconds` counts one-second windows over 0.01, a floor with three
orders of magnitude of RMS to sit in.

Two thresholds off the one measurement, because the two decisions it feeds should
fail in opposite directions. **Five seconds** is enough to transcribe a track:
looking and finding nothing costs a pass, not looking costs whatever was said.
**Thirty seconds** is what it takes to claim somebody was remote, because that
claim is what turns four people into one.

### One voice on the microphone is the user, whatever the flag says

A solo recording at a desk is indistinguishable from a room before the audio has
been clustered: no call app, quiet system track, speech on the mic. Both infer
`room`. That is safe because the mic pass does not trust the flag past the
clustering: **one cluster is labelled `Me`**, exactly as it always was, and only
two or more become letters. A generous inference therefore costs one diarizer
pass and can never cost a wrong name.

Counted over the turns rather than the embeddings. A cluster the model produced
no embedding for is still a voice that spoke, and counting the bank instead
quietly files it under the user.

On a call the mic pass still runs with `expecting: 1`, which is the prior being
used where the answer is genuinely known. That is the difference between the two
paths and it is the whole protection against splitting one person in two.

Measured on the workshop: 5 voices, 180 turns, and turns that alternate the way
a conversation does. Measured on a 33-minute Chrome call: `room: false`, `Me`
and one letter, the same shape as before the change.

### Both tracks are clustered, so the letters are handed out once

Each diarizer run numbers its speakers from scratch, so speaker 1 on the system
track and speaker 1 on the microphone are different people with the same name.
Raw labels are namespaced per track (`Merge.namespaced`), kept namespaced through
assignment, and turned into letters by a **single `Merge.relabel` after the two
tracks are merged and sorted**. That also gives the letters in order of first
speech across the whole meeting, which is what a reader expects and what neither
track alone produces. `Me` is passed in `keeping:` and maps to itself.

### The far end comes back in through the microphone

There is no echo cancellation on the mic track: `MicRecorder` taps the input node
raw. In a hybrid meeting played out loud the far end lands on both tracks, and
without something in the way one remote person attends their own meeting twice.

`Pipeline.bleedClusters` drops a **cluster** whose speech is 80% covered by
system-track speech, not a segment. That is what separates the two cases: a voice
that only ever speaks while the far end is speaking is the far end, while
somebody in the room who talks over them does it occasionally. Dropping by
overlap per sentence would delete exactly the interruptions, which are the
sentences a reader most wants. The 0.8 is chosen, not measured, and the count is
logged every run so that it can be.

Only reachable through the override, since the inference never calls a hybrid
meeting a room. On a call the mic's copy of the far end was still labelled `Me`.
That last sentence used to end "which is the pre-existing behaviour and is
untouched here", and the next section is what it cost.

### A webinar on speakers put the host in the transcript twice, under the user's name

Reported from a 51-minute webinar watched in a browser with the microphone open
and the *webinar's* mute on. Muting in the meeting app stops the far end hearing
you; it does nothing to Listen, which taps the input node raw. So the mic track
held 13.4 seconds of the hosts coming back out of the speakers before macOS put
the built-in mic into its call profile and the track went to digital zero for the
remaining 3046 seconds.

The recording is not a room: the system track carries the whole webinar, so
`decideRoom` correctly infers `room: false` and the call path labels every
sentence on the mic `Me` without clustering it. `bleedClusters` drops clusters,
and there are none, so nothing was in the way. The result on screen was
`Speaker A · 53%`, `Speaker B · 47%`, `Maxime · 1%`, with the user's first six
paragraphs being speaker A's first six paragraphs word for word.

**Coverage cannot decide this, and that is the measurement that mattered.** The
obvious fix is to reuse `bleedClusters`' test on the call path: drop the mic when
its speech is 80% covered by system speech. Over the 54 recordings in the
development library that hold a `Me` speaker, the webinar reads 100% covered, but
an ordinary call ("Call with Nadia", 496 seconds of the user talking) reaches
**82.8%** at paragraph granularity and **68.7%** sentence by sentence. A
threshold there is a coin toss with the whole of what the user said on the table.

What separates is that an echo is not merely simultaneous with the far end, it is
**the same words**. Weighted by duration, the fraction of the mic's words that
are also being spoken on the system track at that moment:

| recording | |
|---|---|
| the webinar | 97.9% |
| next highest (a 29s call, two sentences) | 49.3% |
| third | 21.9% |
| median of the 49 | 6.4% |

`Pipeline.echoedSentences` is that test, and it drops **per sentence**, which is
the opposite of what `bleedClusters` does one section up. The argument against
per-sentence dropping is that an interruption is by definition simultaneous, so
an overlap rule deletes exactly the sentences a reader most wants. Word identity
does not have that failure: an interruption's words are the interrupter's own. So
the finer grain is safe here, and it earns its keep by leaving the three things
somebody actually says out loud during a webinar in the transcript instead of
taking the track away whole.

The comparison is a longest common subsequence, not a set intersection: "and",
"the" and "you" are in everything, and a set would call any sentence built from
common words an echo of any long enough stretch of the far end. In order asks
whether the far end said *this sentence*.

**The floor is where the collateral is, and 4 rather than 3 is a measured
choice.** At 0.9, dropping mic sentences of at least four words costs **7 of the
library's 10726** `Me` sentences: all six of the webinar's, and one stray that is
itself an echo ("Yeah, I don't know." over a far end saying "okay yeah i think
they said ... okay i don't even know"). Three words costs six strays, two costs
33, one costs 268, which is every "yeah" that ever coincided with a "yeah". Five
leaves two of the webinar's six behind. A duplicate left in is one a reader can
see and delete; a real sentence taken out is gone with nothing on screen to say
so, so the floor sits where the last real sentence is safe rather than where the
last echo is caught.

Verified by re-transcribing the recording itself against a scratch
`LISTEN_LIBRARY`: `A` and `B` only, no `Me`, no duplicated paragraphs, and the
two log lines below. The two control calls were re-transcribed the same way and
dropped nothing, including the 68.7% one.

    6 sentence(s) dropped from the microphone: the far end coming back in
    through the speakers
    2026-09-03-170119-3097: no voiceprint from the microphone, every sentence
    on it was the far end

### The webinar host was filed as the user's own voiceprint, and 1.6 seconds saved the bank

The second half of the same bug, and the worse half. `printUser` builds the
user's own voiceprint from the mic track, and on this recording the mic track was
the webinar host. The print written under `Me` sits at **cosine 0.7477 from
speaker A**, where the meeting's two genuine speakers sit at 0.1226 from each
other. It is speaker A's voice, filed under the user's name, in the bank that
names speakers in every recording afterwards.

`VoiceBank.certainThreshold` is 0.75. So the print was one thousandth of a point
below the strength at which Listen names somebody without asking.

The only thing that kept it out of use is that `Voiceprint.isEvidence` requires
15 seconds and the bleed lasted 13.4. **That is a threshold about length standing
in for one about provenance**, and it held by 1.6 seconds. Two more sentences of
the host through the speakers and the bank would have learned the user's voice
from a stranger, silently, with the recording looking exactly the same.

So the guard is now explicit: when every sentence on the microphone was the far
end, `printUser` is not called at all and the recording files no print for the
user. Nothing is inferred from the length of the bleed.

### A silent system track used to be transcribed

`Pipeline.isSilent` has skipped the microphone since the beginning, because
Parakeet over room noise invents confident sentences attributed to the user. The
system track was never asked, because a recording with a silent system track was
assumed not to happen. An in-person meeting is exactly that recording, and it
could grow a participant who was never in the room.

## A paragraph ends at a ten second silence, and discarding a speaker is why

`Merge.turns` folds consecutive segments by one speaker into a paragraph. It used
to fold **all** of them, however far apart, and a turn claims the whole span from
its first segment's start to its last one's end, so the result could be a
paragraph asserting it covers time nobody spoke in, under a single timestamp.

Where that stopped being theoretical is `.discard`. On a two person call,
removing one speaker makes the other's segments adjacent, so on a 4 minute call
sixteen turns became **one**, running 1.9 to 240.7. Every word was still there.
It read exactly like the transcript having been destroyed, and was reported as
"it removed the paragraphs from other speakers too".

`Merge.paragraphGap` is 10 seconds. Measured over the 61 transcripts in the
development library, on the 14037 pairs of consecutive segments by one speaker:

| p50 | p75 | p90 | p95 | p98 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|
| 0.00s | 0.60s | 1.54s | 2.60s | 5.52s | 11.84s | 79.52s | 188.08s |

Ten sits above the 98th percentile and below the 99th: ordinary speech with its
breaths and thinking pauses stays in one paragraph, and the 1.18% of pairs
further apart than that are somebody who has been away for a while. The same
discard now leaves three paragraphs at 1.9, 142.2 and 222.3, which is what
happened.

**It does not cost the playhead.** The highlight depends on `Merge.sentences`
locating every segment's text inside its turn, so the rule was checked against
the whole library before it shipped: 17876 sentences placed and 0 unplaced under
both rules, with 3839 turns becoming 4004. The 165 new breaks are exactly the
pairs measured over 10 seconds apart.

Overlaps come out negative from `segment.start - last.end`, which is smaller than
the gap and joins, as it should: two segments that overlap are one stretch of
speech the diarizer cut in the middle.

Existing `turns.json` files keep their old shape until something edits the
transcript, since that is when they are rebuilt. Nothing reads them expecting
maximal turns.

## The Whisper-era cleanup has not fired on Parakeet yet

`Merge.clean` is ported from `transcribe_call.py`, where it exists because
Whisper falls into repetition loops. Parakeet is claimed not to, so the port
counts rather than assumes: every run reports `cleanup fired: never` or the
rules that fired, and `StoredTranscript.cleanup` stores the counts.

So far it has fired **never**, on synthetic two-speaker audio and on 13 and 67
minute files. That is not yet enough evidence to delete it, because none of
that is real meeting audio with crosstalk and silence. Keep watching the
counts; when there is a real corpus behind the number, either delete the rules
and say so in the commit, or record why they stayed.

## The transcription queue has no database

A recording whose audio exists and whose transcript does not **is** pending.
That one sentence is the whole design: `Queue.resume()` rebuilds the queue by
listing the library at launch, so a job interrupted by a quit or a crash costs
one re-run rather than leaving a stuck row somewhere. Adding a job table would
reintroduce exactly the inconsistency the layout removes.

One job at a time, on purpose. Parakeet is on the GPU and FluidAudio is on the
Neural Engine, and two jobs contend for the same hardware rather than finishing
sooner. `dashboard.py` reached the same conclusion.

### A job that saves the copy it started with erases the hour it ran for

`markTranscribed` re-reads `metadata.json` before writing, the same rule
`Capture.noteApp` follows and for a sharper version of the same reason.
Transcribing an hour is an hour of chances for the folder to have changed: the
title and the tags are editable from the window while the queue works, and
`Pipeline.decideRoom` writes to the file from inside the run.

Found by watching the room decision disappear. The pipeline recorded what it had
decided, the run finished, and `markTranscribed` saved a `Recording` value taken
before any of it and put the old metadata back. The value type is what makes this
invisible: nothing is stale-looking about a struct, and the write succeeds.

### A recording with no audio is not a job waiting to happen

The sentence above is load-bearing and it stops being true the moment a second
Mac can see the library. `SYNC.md` documents putting the folder behind a file
sync tool with the WAVs excluded, which is the right split because the audio is
8.3 GB of an 8.4 GB library and nothing but playback reads it. The consequence is
that the second Mac holds recordings it can never transcribe, and a recording
synced from the other machine arrives as `metadata.json` **before** its
transcript exists, so for those minutes it has neither.

Read literally, "audio exists and a transcript does not" would queue every one of
them at launch, run a job per recording that can only fail, mark each `failed`,
and race the real transcript on its way over. `effectiveState` derives the state
from the files rather than trusting the field, so the wrong state heals itself
and the only surviving evidence is a fan spinning up. That is the worst shape a
bug can take here.

`Recording.hasAudio` is the guard, and it lives in `Queue.enqueue` rather than in
`resume` because there are three callers (launch, `Capture` keeping a recording,
and Transcribe Again) and one rule. `enqueue` returns `Bool` so a caller that is
a control can say why instead of appearing dead.

Three things about it are deliberate:

1. **It tests the audio, not which device recorded it.** A `device` field would
   work and would be a schema change, a migration and a fact that can be wrong.
   The audio is already on disk, it is the thing actually required, and the rule
   stays correct if the WAVs are ever synced too.
2. **The mixdown counts.** An imported recording has only `mix.m4a` and
   `Pipeline.run` transcribes it as the everyone-track, so testing `tracks` alone
   would refuse to transcribe every legacy import.
3. **`hasTranscript` is not the test to use instead.** It is false in exactly the
   window this is about.

`LibraryWindow.validateMenuItem` greys Transcribe Again on the same property.
Both copies of that item go through that one function, the File menu's because it
targets nil and the toolbar's because it is validated the same way, so they
cannot disagree. `DetailView` reads `Recording.hasAudio` too rather than keeping
its own reading of the same folder, and its empty state says the audio is on the
Mac that recorded it rather than "Not transcribed yet", which on that machine is
a promise nothing is going to keep.

Verified against a real launch rather than reasoned about, using `LISTEN_LIBRARY`
to point the app at a two-recording library, one with a track and one without:

    [Listen] not queueing 2026-01-01-000000-NOAUD: no audio on this Mac

and the one with a track went on to load the model.

## The model belongs to the recording, and the language is not a setting

Reported from a real 30 minute call held in Dutch: the transcript is fluent,
confident English and every sentence of it is invented. The model did not fail
and nothing errored. An English-only decoder handed Dutch audio produces English
words, which is the one failure mode of this app that leaves no trace anywhere:
the recording looks transcribed, the state says `needs_labelling`, and the only
evidence that anything went wrong is that a human reads it.

Two things were missing, and the second one is the interesting one.

1. **Nothing said which model made a transcript.** `StoredTranscript.model` has
   held it since milestone 0 and no screen printed it, so "why is this
   gibberish?" was unanswerable without opening the JSON. It is now the fourth
   fact in the detail pane's subtitle and on `listen show`'s second line, always
   rather than only when it is unusual: a fact that appears sometimes is one
   nobody learns to read, and the failure case is the ordinary configuration.
   It earned that immediately. The recording this was written for turned out to
   say `imported: mlx-whisper + pyannote`, not Parakeet at all, so the model
   everyone assumed was at fault was not even the one that ran.
2. **Transcribe Again was a repeat, not a choice.** It re-ran `Settings.model`,
   which is the model that produced the wrong transcript, so the one control on
   screen that looks like the fix was guaranteed to reproduce the fault.

**There is no language picker and this is not the feature that adds one.**
Checked against the pinned mlx-audio rather than remembered:
`STTGenerateParameters.language` exists, and `ParakeetModel` copies it into
`STTOutput` at four places and never hands it to the decoder. A language control
would do nothing at all, silently. The model is the whole lever: v2 is English
only, v3 reads 25 languages and detects which. So the menu says "Parakeet v3 ·
25 languages", not "Dutch".

### The choice is on the recording, because the queue has no job table

`Metadata.asr_model` holds a `ModelChoice.id`, and `nil` is "the app default",
which is every recording written before it. `Optional` for the reason recorded
against `calendar_event_id`: measured before writing a single one, `listen list`
and `listen list --json` both return 31 over a library where no file has the key.

Carrying it on the job instead would have been less code and wrong. `Queue` is
rebuilt at launch from "audio exists and a transcript does not", with nothing
persisted, which is what makes a crash mid-job cost one re-run. A model held
only by the running job is lost by that crash, and the relaunch re-runs the
Dutch meeting on the English-only model and writes the same nonsense a second
time. `Queue.enqueue(_:using:)` therefore writes the choice to `metadata.json`
**before** the job starts, and after the already-queued guard: a job whose
weights are loaded must not have a different model filed against it.

`Recording.asrModel` is the one place the rule lives, and `Pipeline.run` takes
the model as an argument rather than reading `Settings` itself, so nothing can
transcribe with one model while the library records another.

That fixed a real fault next door. `listen transcribe <id> --model v3` used to
do `Settings.model = choice`, so transcribing one meeting permanently changed
the model **every future recording** would use, and nothing said so. `--model`
now files the choice on that recording, and with no flag the recording's own
model wins over the default, which matters because the recordings somebody has
already had to correct are the ones most likely to be run again.

### The submenu, and the three copies of Transcribe Again

The models hang off the item that re-runs, in the toolbar's ellipsis, the
sidebar's right-click menu and the File menu. Four things about it:

1. **The tick is on what produced the transcript**, not on what the next run
   would use, so opening the menu answers "which model wrote this?" in the same
   gesture that changes it.
2. **The coverage, not the blurb.** Settings says v3 "may misdetect short
   clips", which is true and is why `ModelChoice.coverage` exists separately: at
   this click the thing being re-transcribed is a meeting, and a meeting is not
   short, so the caveat would be misleading exactly where it is loudest.
3. **The download is named before the click.** A model that is not on disk says
   "downloads 2.5 GB". `ASR.load` reports the transfer into `Queue.stage` and
   the sidebar row shows it, but that is after somebody has committed to it.
4. **An `NSMenu` can be the submenu of one item only.** The ellipsis and the
   sidebar build a fresh one per open, which they do anyway; the File menu's
   item is built once at launch, so it keeps one instance, refilled by
   `menuNeedsUpdate` and filled once at creation because AppKit will not open an
   empty submenu and a parent that cannot open is an item that does nothing.

The parent item keeps its `retranscribeSelected` action even though AppKit sends
no action for an item with a submenu. That is what keeps both copies going
through `validateMenuItem`, which is the property the section above this one
depends on.

### Transcribing again destroys hand corrections, and now says so

`Pipeline.write` overwrites `transcript.json`, `turns.json` and
`embeddings.json`, so a re-run discards every speaker somebody named and every
sentence they corrected. Nothing asked, which was survivable while the item was
a repeat of itself and is not now that it is a choice: choosing a model is what
somebody does to a transcript they have already been through by hand.

`Recording.hasHumanEdits` gates the alert, and what it counts is the point.
`Me` does not count, because the pipeline writes it rather than a person, and a
placeholder letter does not count either, because nobody chose that. Counting
either would put a confirmation in front of every recording in the library,
which is the same as putting one in front of none of them. The recording this
feature was written for has Speaker A and Speaker B and correctly asks nothing.

The other half is the `.raw.json.bak` that `TranscriptEditor` writes once before
the first sentence edit. Its path moved onto `Recording` because that file now
has a second reader: its existence is how the app knows somebody has corrected a
sentence in a transcript it is about to throw away.

## The model is chosen during the call, because afterwards it costs an hour

Transcribe Again was the only control over the model, and it is the expensive
one: it is offered after a meeting has been read once with the wrong model, and
paying for it means transcribing an hour of audio twice. The person who knows a
call will be in Dutch knows it at the start of the call, not at the end of it.
So the choice is now on the recording screen, on the row that already names the
microphone, and it writes the same `Metadata.asr_model` that Transcribe Again
writes. Nothing else changed: `Capture.stop` re-reads `metadata.json` from disk
before it saves, `keep` promotes those bytes, and `Queue.transcribe` resolves
`Recording.asrModel` rather than the app default, so the choice made at 15:27
is the model that runs at 16:03 without a single new hop.

**Filing a model mid-capture touches nothing that is being written to.** The
model is a field in `metadata.json`; the audio is two WAVs beside it whose
headers are rewritten as they grow. That is the whole reason this is the one
item the actions menu may offer during a recording, where Export, Transcribe,
Recorded in the Room and Delete are all deliberately absent: it does not act on
the capture at all, it files a decision about a job that has not started.

Three details, each of which was a bug first or would have been.

1. **Every writer re-reads the file.** `Recording.setModel` is a
   read-modify-write of `metadata.json` and never a save of the caller's copy,
   because both controls that reach it sit on a screen that stays up for the
   length of a meeting: the `Recording` behind them is an hour old, and saving
   it back would undo a rename or a calendar match made in between. That is the
   same bug `Capture.stop` records against saving the copy it took at `start`,
   and it is reachable here in one more way, since the two controls write the
   same field behind each other.
2. **The title is the coverage, not the name.** The pull-down says "Parakeet v2
   · English only" rather than "Parakeet v2". The fact that decides anything at
   15:27 is the second half, and it has to be legible without opening the menu,
   because somebody who opens the menu has already had the thought this control
   exists to prompt.
3. **The File menu could queue a live recording, and now cannot.**
   `validateMenuItem` gated Transcribe Again on `selected?.hasAudio == true`,
   which is *true* while a meeting records: the WAVs exist and are growing. The
   toolbar and sidebar copies were never built mid-call so this only ever fired
   from the menu bar, where it would have transcribed half a meeting while the
   other half arrived. Live is now `false` there, and the choice-only item is
   `true` only while live.

`Recording.setModel` is the shape a hand-edit can take too, which is how the
mechanism was first proved: writing `"asr_model": "v3"` into a staging
recording's `metadata.json` while the call ran, on the shipped 0.23.0 build,
comes out as a v3 transcript after Stop. Anything in the app that wants to
choose a model before the job exists writes that one key.

### How both halves were checked, since neither is reachable without a meeting

A real capture, against a scratch `LISTEN_LIBRARY`, driven by `axprobe`. The
sequence, which is the whole test:

```sh
LISTEN_LIBRARY=$LIB Listen.app/Contents/MacOS/Listen &     # never `open`
axprobe press    $PID "New Recording"    # ⌘N toggles record and stop
axprobe showmenu $PID "Parakeet v2 · English only"   # the pane's pull-down
axprobe press    $PID "25 languages"
axprobe showmenu $PID "Actions"          # the toolbar's ellipsis
axprobe press    $PID "Parakeet v2 · English only"   # its Transcribe With row
axprobe press    $PID "New Recording"
```

Measured: `asr_model` absent at the start, `v3` after the pane's pick with the
button's own title following it to "Parakeet v3 · 25 languages", `v2` after the
menu's, and the last choice still in `metadata.json` under `recordings/` after
Stop, on a 10 second recording that promoted to `state: done`.

**`AXPress` does nothing to any of these controls**, and that is worth knowing
before reading a failure. An `NSMenuToolbarItem` and an `NSPopUpButton` both
answer `AXShowMenu` and both return success and do nothing at all on a press,
so a first attempt at this reported "pressed" four times and changed no file.
A menu's items are in the tree only while it is open, which is also what makes
this readable: with the ellipsis open the dump holds the live menu entire, in
order, Close then Transcribe With with its two rows then Discard Recording.

That same first attempt proved the File menu half by accident. Pressing its
Transcribe Again model row against a running recording did nothing, because AX
goes through `NSMenu`'s own validation and `validateMenuItem` now answers false
while live. On the build before this one it would have queued the job.

## The model is cached twice, and deleting one copy does not test anything

`ModelChoice` names two directories under the same hub root, and they are not
alternatives:

- `downloadDirectory`, `models--mlx-community--parakeet-tdt-0.6b-v2`, the
  Hugging Face blob cache the transfer streams into.
- `cacheDirectory`, `mlx-audio/mlx-community_parakeet-tdt-0.6b-v2`, mlx-audio's
  own unpacked copy, and **the only one `isDownloaded` looks at**.

So `bytesUsed` sums them and `bytesOnDisk` takes the maximum, which is why the
Models pane reports about 4.9 GB for a model whose download is 2.5 GB.

The consequence cost a testing round. Moving `mlx-audio` aside to force a
first-run download does not force one: the blob cache is still there, so
`resolveOrDownloadModel` finds it populated and re-copies locally, in seconds
and with no network. Measured on a second Mac, where the listing afterwards
held **both** `mlx-audio` and `mlx-audio.bak`, and the pane correctly reported
the model as present. That reads exactly like the pane lying, and it is not.

Forcing a real download means moving both, which also takes Speak's model away
when Speak is installed, because that is the whole point of a shared cache.

## The cache root is not always `~/.cache/huggingface`

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

## mlx-audio prints to stdout, and stdout is the transcript

`ModelUtils.resolveOrDownloadModel` prints `Using cached model at: <path>`
with a bare `print()` and no flag to suppress it, and `STT.loadModel` resolves
the model again internally, so it lands three times. On the CLI that is three
lines of library chatter in the middle of piped output.

`withStdoutOnStderr` dups stdout to stderr around model loading. It is safe
only because loading is serialized by the `ASR` actor and nothing else in the
process writes to stdout while it runs.

## A silent track must not cost a transcript

FluidAudio throws "No speech detected in audio" rather than returning nothing,
and plenty of recordings genuinely contain a silent track: a webinar nobody
spoke into, a call taken on mute. That exception used to abort the whole
recording, so a meeting with one live track produced neither voiceprints nor,
in `Pipeline`, a transcript.

Both now catch it. `Enroll` takes whatever the other track gives; `Pipeline`
keeps the transcript and puts everybody under one label, because a transcript
with imperfect speakers is worth enormously more than no transcript.

## A model directory that exists is not a model, and both ways it can lie were measured

mlx-audio decides a model is already downloaded by looking for **any non-zero
`.safetensors` beside a parseable `config.json`**. It never checks a size, so
every damaged copy on disk is adopted rather than replaced, and neither of the
two ways that goes wrong says anything a person could act on. Both were
staged through the CLI against Parakeet v3:

- **Short.** 1.4 GB of the 2.5 GB file loads with **no error at all** and
  transcribes five seconds of clear speech to nothing. MLX reads past the end
  of the file as zeros rather than failing, which was confirmed separately in
  Python: a safetensors cut to 60% still lists every key, and evaluating a
  tensor that lies wholly past the end returns zeros.
- **Absent.** A directory whose `model.safetensors` carries no tensors throws
  `Key <some weight> not found in ParakeetModel…`. **The weight it names is
  meaningless**: it is whichever one `items()` happened to yield first, and
  Swift seeds dictionary hashing per process, so the same directory said
  `joint.enc.weight` here and `decoder.prediction.embed.weight` on the Mac
  where it was reported.

So the size Listen already knows is the only thing between a half-written
directory and an empty transcript. `ModelChoice.approxBytes` is exact rather
than approximate, which is what makes this usable: a finished copy is
`config.json`, `vocab.txt` and `model.safetensors`, and downloading into an
empty cache reproduces the constant to the byte (2,508,579,601 for v3,
2,471,601,146 for v2). `isDownloaded` keeps a 3% margin anyway.

`ASR.load` now refuses to load anything short, **after** the library says it is
done, and says how short. It does not delete: the library streams into that
directory, and a caller that cannot see whether a download is in flight must
not remove it. Deleting belongs to `ModelDownload`, which knows there is no
download running because it is the only thing that starts one.

## A copy of the right size that will not load has to be replaceable

The size check above cannot see a file that is complete and corrupt, and there
is no cheaper test than loading it. That leaves a state with no way out unless
something explicitly breaks it: every retry reads the same bytes and reports
the same thing.

`ModelDownload` remembers the model whose last attempt failed, and a second
press deletes the copy before fetching. Only after a failure, and only on a
press: throwing away 2.5 GB on a hunch is worse than the problem.


## One engine for the process, and a yield so dictation can interleave

`ASR.shared` is the only instance the app builds. The weights are about 2.5 GB
resident and both the meeting queue and dictation want them, so two instances is
two copies, which is the difference between fitting and not fitting on an 8 GB
Mac. Nothing changed for meetings: `Queue.shared` already held one `Pipeline`
for the life of the process, so its engine was a de-facto singleton already. The
CLI still builds its own where it runs one job and exits, because there is
nothing to share with.

`transcribe(samples:)` is the dictation entry point. A meeting is an hour on
disk that needs pieces, timings, segments and a progress count; a dictation is a
few seconds that never touched a file and needs one string. Writing a temp WAV
to reach `transcribe(_ url:)` would round-trip through the encoder and the
decoder for nothing, since Parakeet takes an `MLXArray` and that is what the
recorder already has. It pads to one second for the same reason the file path
does.

`transcribe(_ url:)` is `async` for exactly one reason, and it is not the
decoding: the `await Task.yield()` at the top of the chunk loop. An actor method
with no suspension point runs to completion before anything else on the actor
gets a turn, so a dictation asked for while an hour-long recording transcribes
would wait for the whole hour, which is 30 pieces at roughly a second each. The
yield lets a queued dictation run between pieces and bounds that wait to one.

The transcript is unaffected and the reentrancy is safe: each piece decodes from
`flat`, which nothing else writes, and the accumulators are actor state only
that call touches. A reentrant dictation reads no part of them.

## MLX keeps every buffer it ever freed, until it is told a limit

**The "Listen is using 30 GB" report is not a leak, and no Swift allocation is
involved.** MLX pools every Metal buffer it frees, and its default ceiling for
that pool is its memory limit: 1.5x the machine's recommended working set. On
a large Mac that is more than the machine, so the pool never evicts, and macOS
charges all of it to Listen. `footprint` on the process mid-transcription made
the attribution unambiguous: 45 GB of a 47 GB footprint was dirty
`IOAccelerator (graphics)` memory across 3,765 regions, with under 1 GB of
ordinary malloc.

The growth is content-dependent, which is what made the first measurement lie.
Decoding a silent track emits nearly no tokens and stayed flat at 5.8 GB, so
the CLI looked innocent; the same build on the same meeting's speech-bearing
track went to 27 GB in 14 seconds. Decode allocations come in sizes that
rarely repeat, so the pool grows instead of being reused. All measured on a
128 GB machine against the 75 minute meeting `2026-08-18-170206-0912`:

| run | peak footprint |
|---|---|
| CLI, silent system track (different meeting) | 5.8 GB, flat |
| CLI, speech-bearing system track | 27 GB in 14 s |
| GUI queue, three copies of the meeting | 47 GB, held while idle |

Idle is the operative word in the last row: the pool is only returned when the
process exits, and the app is left open, so the user sees tens of GB against
an app doing nothing.

Two lines fix it, both in `ASR`. `Memory.cacheLimit` is set in `load`, the one
place every consumer of the model passes through, and `Memory.clearCache()`
runs when `transcribe(_ url:)` finishes so a done job hands even the capped
pool back. 512 MB is measured, not guessed: same track, decode 14.4 s uncapped
against 14.7 s capped, peak 27 GB against 3.2 GB, transcript byte-identical.
The full queue harness over three meetings then plateaued in single digits
where the uncapped build sat at 47 GB.

Dictation deliberately keeps its pool between utterances: many short clips are
the one shape here whose allocation sizes recur, and the cap bounds it anyway.
`LISTEN_MLX_CACHE` overrides the cap in whole MB for measurement, 0 disabling
the pool; it is `LISTEN_CHUNK`'s sibling, not a user setting. The mlx-swift
`GPU.set(cacheLimit:)` spelling is deprecated in the pinned revision; the
property is `MLX.Memory.cacheLimit`.


## A threshold measured on a 47-minute meeting drops the far end of a 9-second call

`Pipeline.run` decides twice from one measurement of the system track: whether
to transcribe it at all, and whether anybody was on the far end. Both numbers
were absolute seconds read off the meeting `signalSeconds` documents, and an
absolute second count cannot be asked about a recording shorter than itself.

Reported from the first install on somebody else's Mac: a Telegram call between
two people, plainly two voices, came back as one speaker talking to themselves
with the other half of the conversation missing. Measured on the recording they
sent, 9.5 seconds, both tracks loud:

    mic.wav     peak 0.330   8 of 10 seconds over 0.01
    system.wav  peak 0.850   3 of 10 seconds over 0.01

`system.wav` transcribes to "Hello. Okay." on its own through
`listen transcribe`. Under `systemSignal >= 5` it was never transcribed at all:
the whole system branch is skipped, so there is no second transcript, no second
diarization and no second speaker. The stored transcript held the mic track
alone, labelled `Me`, which is exactly what the screenshots showed. It reads to
a user as two bugs, a diarizer that cannot hear two voices and a transcriber
that swallows words, and it is neither.

`somebodyRemote >= 30` is worse in the same way: nine seconds of audio cannot
contain thirty seconds of speech, so a short call in an app Listen does not
recognise can never be read as a call.

Both are now fractions of the track with the old seconds as a **ceiling**, in
`enoughToTranscribe` and `enoughToBeACall`, and `signal` returns the window
count alongside the signal so the two are on one scale. Nothing about a long
meeting moves: at 2828 seconds both `min`s take the constant. Checked against
the real library rather than argued, 48 recordings with a system track, 37
seconds to 7485 seconds, **zero changed either decision**, including
`2026-08-07-101300-BE35`, which is the 2829-second meeting the original numbers
were read off.

Below about 33 seconds the fraction binds instead. A chime keeps failing it: a
two-second chime in a twenty-second recording needs three seconds and has two.
Under about ten seconds nothing can tell a chime from a voice, and the trade is
deliberate: the cost of being wrong is one Parakeet pass over ten seconds, and
the cost of the old answer was half of every short conversation.

## The model download reset to 0% and stayed there, on a reading of 41 KB

`ModelChoice.inFlightBytes` finds the transfer by looking for the most recently
written `CFNetworkDownload` file in the temp directory, within a ten second
window. That window is the right rule for **adopting** a file, and it was also
being used to abandon one.

A transfer that pauses longer than ten seconds, on a network hiccup or while
the finished file is moved into place, stops qualifying while still sitting
there holding every byte fetched so far. `bytesOnDisk` then falls back to the
two JSON files already in the hub cache. Reported, with the screenshot: a
2.47 GB download reached very nearly the end and then read `41 KB of 2,47 GB`.

It stuck there because the guard in `ModelDownload.startWatch` caught only an
exact zero:

    if bytes == 0 { bytes = self.lastBytes }   // 41_000 is not 0

So the collapse went through, and `lastBytes` was then poisoned with 41 KB and
could never recover. Two changes, and both are needed: `inFlightBytes` follows
the file it adopted by path until it disappears, and the guard is now "never
backwards", which is true of every quantity it is applied to because within one
download the bytes on disk only grow. The abandoned-file trap the original note
records is still closed: `previous` is only ever a file this process watched go
live, so none of the stale temp files on a real machine can be picked up by it.
