# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

## 0.1.0 (2026-08-05)

First release. Listen records a meeting from both sides, transcribes it, and
works out who said what. Everything runs on your Mac and nothing is uploaded.

### Before you start

- Apple silicon, macOS 14 or later. Capturing the other side of a call needs
  macOS 14.2; on 14.0 and 14.1 Listen records your microphone only.
- The speech model is about 2.5 GB. It downloads the first time you transcribe
  something, not during install.
- Two permissions on first launch: microphone, and audio recording. It asks for
  audio recording and **not** screen recording. Calendar access is optional and
  buys one thing, naming a recording after the meeting already in your diary.

### Worth knowing before you record a real meeting

- **Meeting detection is on by default.** Listen starts recording when it sees
  one app using the microphone and the speakers at once, and then asks on
  screen whether you are actually in a meeting. Answering no deletes the audio
  straight away. It over-triggers rather than under-triggers, on the grounds
  that a recorder you have to remember to switch on is switched off for the
  meeting you needed it for.
- **Speaker labelling is per sentence, not per word.** Two people talking over
  each other inside a single sentence come out as one speaker.
- **About six words an hour are corrupted** where the transcriber's chunks
  meet. Known, measured, and being fixed by cutting chunks at silence.
- Nothing asks "keep this recording?" at the end. A recording that exists is
  kept, and Delete in the library is how one goes away, where you can hear it
  first.

### If something goes wrong

`listen transcribe some.wav` needs no permissions at all, which makes it the
quickest way to tell a model problem from a capture problem.

Reports and confusion are both useful: https://github.com/mugoosse/listen/issues
