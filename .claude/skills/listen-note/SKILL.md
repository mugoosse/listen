---
name: listen-note
description: Write a note artifact back into a Listen recording, so an answer about a meeting outlives the chat it was asked in. Covers write_note, edit_note and delete_note, the compare-and-swap on edits, and when a note is worth writing at all. Use when the user asks for a summary, decisions, action items or any other write-up of a meeting, or says to save something to Listen.
---

# Writing a note into Listen

Listen owns the recording, the transcript and who spoke. It does not summarise,
and there is no model inside it that could. **Notes are how thinking gets back
into the library**, and they are the only thing an agent may write: you cannot
rename a speaker, correct a transcript or delete a recording through this server.
That boundary is deliberate. The transcript is evidence of what was said, notes
are derived from it, and a wrong note is a wrong opinion where a wrong transcript
edit is a lost fact.

Read the `listen-library` skill for finding the meeting. This one is about what
happens after.

## 1. Decide whether this is worth keeping

Write a note when the answer should still be there in a month:

- The user asked for a summary, the decisions, the actions, the open questions.
- You worked something out that took real reading and would have to be redone.
- The user said to save it, or to write it down.

Do not write a note for a question you just answered in the conversation. A
library where every query leaves a file behind is a library nobody can find
anything in, which is how every note app fails. When in doubt, answer in the
chat and offer to save it.

## 2. Write it

```
write_note {
  "recordings": ["2026-07-14-150912-A1B2"],
  "title": "Decisions",
  "body": "# Decisions\n\n- Ship the notes store before the UI…",
  "prompt": "what did we actually decide in this call"
}
```

- **`recordings`** is a list, and that is the point rather than a formality. A
  note answering "summarise everything with Edgar in June" names **all four**
  meetings it drew on. Filing it under one of them arbitrarily, duplicating it
  into all four, or not writing it were the three bad options before this
  existed. Name every meeting you actually read; nothing here infers them, and
  there is no wiki-link syntax and no automatic linking.
- **`title`** is free text and becomes the filename. A few words, not a
  sentence: it is what the switcher in the app shows and what `list_notes`
  returns. There is no fixed set of kinds, so `Decisions`, `Action items`,
  `What Ryan is worried about` are all equally valid.
- **`body`** is markdown. Headings, bullets, numbered lists, tables, bold and
  blockquotes all render in the app. Keep it to what the transcript supports.
- **`prompt`** is what you were asked for, in the user's words where you have
  them. Always pass it. There is no template feature in Listen because the
  prompt *is* the template: somebody reading this note in six weeks needs to know
  what question it was answering, and the app puts it on screen above the note.

`write_note` never overwrites. A title already in use is numbered, so the slug
that comes back may not be the one your title implies. Use the returned slug for
anything afterwards.

## 3. Quote, attribute, and do not invent

A note lives beside the recording and outlives the conversation, so it has to
stand on its own:

- Attribute claims to the person who made them, by the name `list_people` gives.
- Carry timestamps for anything worth going back to. `**14:24** Daniel:` is one
  click from the audio in the app.
- If the transcript does not settle something, say so in the note rather than
  smoothing it over. "Not decided on the call" is a useful line.
- Never state as fact something no turn supports. The transcript is right there
  and the user can check.

## 4. Editing an existing note

```
read_note {"note": "decisions"}
edit_note {"note": "decisions",
           "body": "…the new markdown…",
           "was":  "…the body read_note just returned…"}
```

`was` is required and is a compare-and-swap. The user can have the note open in
the app and another agent can be holding it too; without the check, whoever read
it first would write over an edit they never saw and nothing anywhere would
report it. If the write is refused, **read the note again and rebase your
changes onto what is actually there**. Do not retry with the same `was`, and do
not work around it by deleting and rewriting.

Adding to a note means reading it, appending, and writing the whole body back.
There is no append operation, on purpose: the compare-and-swap is what makes
concurrent writers safe and an append would skip it.

## 5. The user's own note is read-only to you

Every recording can carry one note the user types themselves: `source: "you"`,
slug `<recording-id>-yours`, title "Your notes". It holds what they were
thinking during the call, which is in no transcript and cannot be regenerated
from anything.

**Read it. Never write it.** `edit_note` and `delete_note` refuse it with a
message saying so. That is not a bug to work around: the transcript is evidence,
their note is their thinking, and only notes an agent wrote are yours to change.
If you have something to add to what they wrote, `write_note` a separate note
that references the same recording. There is no limit on how many a recording
can have.

## 6. Deleting

```
delete_note {"note": "decisions"}
```

The only destructive tool on this server. Ask first unless the user has just
told you to remove it. A deleted note is gone; there is no trash.

## Things that will bite you

- **The slug is the identity, not the title.** Two notes can share a title, and
  every recording's own note is titled "Your notes". `list_notes` returns the
  slug, and every tool takes it.
- **`edited_by_hand: true` on a note means a person has been in it.** Rewrite
  it carefully, or write a new note beside it, and never delete it without asking.
- **`recordings` on `edit_note` replaces the list, it does not add to it.**
  Omit it unless the sources really changed.
- **Deleting a recording does not delete notes about it.** The id stays in
  `recordings` and comes back under `unresolved_recordings`. That is deliberate,
  so a synthesis of four meetings does not vanish because one was tidied up. Do
  not offer to clean it up.
- **The app does not watch the folder continuously.** It re-reads notes when it
  comes back to the front and when the user switches to the Notes tab, so a note
  you write while they are looking at the window appears the moment they touch
  it, not before.
- **Nothing here can fix a wrong transcript.** If the user says a name is wrong
  or a sentence is misheard, tell them to use `listen label`, `listen edit`, or
  the window. Do not write a note correcting the transcript and treat it as done.
