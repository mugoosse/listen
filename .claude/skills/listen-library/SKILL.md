---
name: listen-library
description: Find things across a Listen meeting library without reading every transcript. Walks the retrieval ladder from cheap metadata to expensive transcript text, with the token budget for each step. Use when the user asks what was said in a meeting, what somebody thinks about something, what was decided, who they have spoken to, or anything else that means searching their recorded calls.
---

# Reading a Listen library

Listen records meetings, transcribes them and labels who spoke. The library is
markdown and JSON files on disk; the MCP server serves them read-only apart from
notes, and the `listen` CLI does the same thing without an MCP client.

**The whole skill is one idea: narrow before you read.** Transcripts are the
only expensive thing here and everything else exists so you can decide which
ones you need. There is no summary layer, no index and no embedding store, and
there does not need to be. The numbers, measured on a real 33-recording library:

| | |
|---|---|
| average meeting | ~5,500 tokens |
| 200k context holds | ~36 whole meetings |
| four two-hour catch-ups with one person | ~79,000 tokens |
| a library of 2,000 meetings | ~30 MB of text in total |

So the limit you will meet is the context window, never the disk. Reading
fifteen transcripts to answer a question that three would have answered is the
only way to fail at this.

## 1. Work out who or when, not what

Start with the two filters that read no transcript text at all.

```
list_people
list_recordings  {"person": "Edgar", "after": "2026-07-01", "before": "2026-07-31"}
```

`list_recordings` takes `query`, `person`, `after`, `before`, `limit` and
`offset`, and they combine with AND. Dates are `YYYY-MM-DD` or a full ISO 8601
timestamp; a bare day covers the whole of it, so `before: "2026-07-14"` includes
everything recorded on the 14th. `person` here means **was in the room**.

Two things about names, both of which return an empty list rather than an error
when you get them wrong:

- Matching is case-insensitive, and both the stored label and the displayed name
  work. The user's own track is stored as `Me` whatever they have called
  themselves, so both answer.
- `list_people` prints the name to use, and adds `label` on the one row where
  the two differ. Run it first if you are unsure.

If you already know the phrase, skip the ladder:

```
search_transcripts  {"query": "pricing", "person": "Edgar"}
```

`person` means something different here: **said by**, not was in the room. "What
has Edgar said about pricing" is this call. "Which meetings was Edgar in during
July" is the one above.

## 2. Read the notes before the transcript

```
get_recording  {"recording_id": "2026-07-14-150912-A1B2"}
```

Metadata, participants, speaker names, turn count, and the slugs of every note
that names this recording.

```
list_notes  {"recording_id": "..."}     the notes about one meeting
list_notes  {}                          every note in the library, newest first
read_note   {"note": "<slug>"}
```

Two kinds of note, and the difference matters more than anything else in this
skill:

- **The user's own note**, `source: "you"`, slug `<recording-id>-yours`. What
  they typed during or after the call. **This is the single most valuable thing
  in the library and it is in no transcript**: "we should upsell them", "he was
  lying about the timeline", "ask Ryan before agreeing". Read it first, always.
  You may not write it, see the `listen-note` skill.
- **Notes an agent wrote**, `source: "agent"` or `"cli"`. Somebody's earlier
  answer about this meeting. Useful, and derived: if it disagrees with the
  transcript, the transcript wins.

A note is a few hundred tokens against a transcript's several thousand, and
often enough to decide whether the transcript is worth reading at all.

**A note is not evidence.** When the answer matters, quote the transcript.

### A note can be about several meetings

`recordings` is an array. A note answering "summarise everything with Edgar in
June" names all four meetings rather than being filed under one of them, so it
comes back from `list_notes` on each of them and from `list_notes {}` once.

An id in `recordings` with no recording behind it is a meeting that has been
deleted. It stays listed, and `unresolved_recordings` names it. Do not treat it
as an error and do not offer to tidy it up.

## 3. Read the transcript, paginated

```
get_transcript  {"recording_id": "...", "offset": 0, "limit": 200}
```

Speaker turns, oldest first, 200 at a time and 500 at most. `pagination.next_offset`
is present only when there is a next page, so loop on its presence rather than on
arithmetic.

## 4. Say which meeting each thing came from

Every claim you make from a transcript should carry the recording and the
timestamp it came from. The user can click a timestamp in the app and hear it,
which is the difference between an answer they can check and one they have to
trust.

## Without an MCP client

Every one of these has a CLI equivalent, which is also how to check what the MCP
server is seeing:

```sh
listen list --limit 20            # recordings, newest first
listen show <id>                  # metadata and transcript
listen people                     # who is in the library
listen notes list                 # every note in the library
listen notes list <id>            # the notes about one recording
listen notes read <slug>          # one note, body on stdout
listen export <id> --format txt   # the whole transcript, pipeable
```

## Things that will bite you

- **An empty result is not "no such person".** A filter that matched nothing and
  a name that does not exist look identical. Run `list_people` before concluding
  somebody is not in the library.
- **`Speaker A` is not a person.** A bare letter means the diarizer found a voice
  nobody has named yet, and `A` in one recording has nothing to do with `A` in
  another. Never join two recordings on a placeholder.
- **Do not fetch every transcript to be thorough.** Thirty-six meetings is one
  context window with nothing left for thinking. If the shortlist is longer than
  about five, narrow it further before reading.
- **The recording in progress has no transcript.** A meeting that is still being
  captured, or is still in the queue, has metadata and nothing else. It can
  already have the user's own note, though, because that is editable while the
  recording runs. On a live meeting it is the only thing there is to read.
- **Do not paraphrase the user's own note back at them.** They wrote it. Use it
  as context for the question they actually asked.
