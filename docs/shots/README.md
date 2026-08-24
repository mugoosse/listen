# Clips

Each feature section of the site looks for a clip here, named after that
section's `data-shot`:

```
hero.mp4        the film at the top, played on a press, with sound
record.mp4      speakers.mp4    ask.mp4
playback.mp4    notes.mp4       dictate.mp4     sync.mp4
```

Those seven are silent loops, autoplayed and looped, no controls. A poster is
optional and goes beside its clip as `<name>.jpg`.

A frame whose clip is missing keeps whatever it has: the still it shipped with,
its poster, or a placeholder naming the file. So this folder can fill up one
recording at a time and the page is deployable at every step.

[`../SHOTS.md`](../SHOTS.md) is the shot list.
