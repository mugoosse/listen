# The MCP server

`listen mcp` speaks the Model Context Protocol over stdin and stdout, so an agent
on this Mac can read your meetings. It opens no port, and the app does not need
to be running: the library on disk is the source of truth.

The [README](README.md#mcp) has the short version and the boundary this server
keeps. This is the reference.

## Connecting a client

The server speaks over a pipe, so the agent has to be on the same Mac as the
library. Any client that launches a stdio MCP server works. Claude Desktop takes
the JSON above; the others have a command.

**Claude Code**

```sh
claude mcp add listen -- /usr/local/bin/listen mcp
```

**[Hermes Agent](https://hermes-agent.nousresearch.com)**

```sh
hermes mcp add listen --command /usr/local/bin/listen --args mcp
hermes mcp test listen
```

`--args` has to be last. Then start a new session, or `/reload-mcp` in one that
is already open.

**Hermes profiles do not inherit MCP servers.** Each has its own `config.yaml`
under `~/.hermes/profiles/<name>/`, so a server added to the default profile is
invisible from every other one, with nothing reported. Add it per profile:

```sh
hermes mcp add listen --command /usr/local/bin/listen --args mcp   # default
hermes -p career mcp add listen --command /usr/local/bin/listen --args mcp
```

If you reach Hermes through its messaging gateway rather than a terminal, that is
a long-running process and wants `hermes gateway restart`.

Enable all thirteen tools rather than picking a subset. Hermes writes the chosen names
into the config as an `include` list, which freezes the surface: a tool added in
a later version of Listen would then be missing until you re-ran
`hermes mcp configure`. The one destructive tool, `delete_note`, already refuses
to touch your own notes.

The commands above use `/usr/local/bin/listen`, which is where the CLI lands when
that directory exists. Without Homebrew it does not, and the install goes to
`~/.local/bin/listen` instead. Settings, Developers prints the real path, and
`command -v listen` confirms it.

**Point any client at the installed app**, either the `listen` symlink or
`/Applications/Listen.app/Contents/MacOS/Listen`. Both survive an update, because
the config stores a path and Sparkle replaces the app at that same path, so a new
version is picked up on the next session with nothing to re-register. A path into
a build directory does not survive an update, and neither would a copy of the
binary, which is why the installed command is a symlink rather than a copy.

## The tools

| tool | what it answers |
|---|---|
| `list_recordings` | which meetings match, as metadata only |
| `get_recording` | who was in one meeting, whether it has a transcript, which notes |
| `get_transcript` | the speaker turns, paginated |
| `search_transcripts` | which turns anywhere contain a phrase |
| `list_people` | everyone the voice bank knows, and how much they talk |
| `list_tags` | every tag you have used, and how many recordings and notes carry it |
| `add_tags` | tag a recording or a note. Adds to what it has rather than replacing it. |
| `remove_tags` | take tags off a recording or a note |
| `list_notes` | the notes on one recording, or all of them, or the ones with a tag, without their text |
| `read_note` | one note in full |
| `write_note` | add a note. Markdown body, free-text title, one or more recordings |
| `edit_note` | rewrite one, refused if it changed since you read it |
| `delete_note` | remove one |

`list_recordings` takes `query`, `person`, `tags`, `after`, `before`, `limit` and
`offset`. They combine with AND:

```json
{"person": "Edgar", "after": "2026-07-01", "before": "2026-07-31"}
```

`tags` is a list, and a recording has to carry all of them. It is usually the
right way to name a subject, because the meetings that belong to one rarely
share a word: a recruiter screen, a hiring manager chat and a referral catch-up
have no phrase, no attendee and no week in common, and `{"tags": ["job hunt"]}`
finds all three.

The names are invented by the user rather than drawn from a fixed list, so call
`list_tags` first instead of guessing. Matching ignores case.

### One vocabulary, and nothing inherited

Recordings and notes share one set of tag names. `list_tags` returns each name
once, with a count of the recordings carrying it and a count of the notes, and
either can be zero: a tag that only notes carry is still a tag. Adding one
adopts whatever spelling the library already has, so `add_tags` with `Kinsight`
onto a library holding `kinsight` files it under the one that is there, whether
you are tagging a meeting or a note.

**A note does not inherit its recording's tags.** Tagging a meeting `kinsight`
does not tag the notes about it, so filing a subject means doing both. This
keeps the two questions apart, and they are different questions:

```json
list_recordings {"tags": ["kinsight"]}   what was said in meetings filed under it
list_notes      {"tags": ["kinsight"]}   what has been written up and filed under it
```

`add_tags` and `remove_tags` take `recording_id` **or** `note`, never both.
Giving both is refused rather than resolved in some order, because a tag on a
meeting and a tag on the write-up of it are two different claims.

`write_note` takes an optional `tags`, and `edit_note` takes one that replaces
the list rather than adding to it, exactly as its `recordings` does. Omit it and
the filing is left alone.

The one write that may touch the user's own note is a tag. Its words cannot be
changed from here, for the reason a transcript cannot: they were not derived
from anything and there is no way to get them back. A tag is filing, and it is
one click to remove in the window.

`after` and `before` take `YYYY-MM-DD` or a full ISO 8601 timestamp. A bare day
covers the whole of it, so `before: "2026-07-14"` includes everything recorded
on the 14th rather than stopping at midnight. Anything else is refused with a
message rather than quietly matching nothing.

`search_transcripts` takes `person` too, and it means something different there:
`list_recordings` with a person finds meetings they were **in**, and
`search_transcripts` with a person finds turns they **said**. "What has Edgar
said about pricing" is the second one.

Names are matched case-insensitively, and both the stored label and the name you
see work. Your own track is stored as `Me` whatever you have set your name to,
so both answer. `list_people` prints the name to use, and adds `label` on the
one row where the two differ.

## Working through a large library

Transcripts are long and there is no summary layer, so the tools are shaped to
be walked from cheap to expensive rather than read whole:

1. `list_tags`, `list_people`, or `list_recordings` with `tags`, `person` and a
   date range. Metadata only, no transcript is read.
2. `get_recording` on the shortlist, to see who is in each and how long it ran.
3. `list_notes` and `read_note` on the ones that look promising. A note is a few
   hundred tokens against a transcript's several thousand, and your own note on
   a meeting is often the whole answer.
4. `get_transcript` on the few that matter, paginated.

`search_transcripts` short-circuits that when you already know the phrase.

For scale: an average meeting here is about 5,500 tokens, so a 200k context
holds roughly 36 of them in full. Four two-hour catch-ups with one person come
to about 79,000 tokens, which fits in one go. A library of 2,000 meetings is
around 30 MB of text in total, so the limit you will meet is the context window
rather than anything on disk.

