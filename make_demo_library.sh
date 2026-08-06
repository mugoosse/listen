#!/bin/sh
# Build a library of invented meetings, for screenshots.
#
# Nothing here is real. The whole point is that a screenshot on the website
# never contains a customer's name, a colleague's voice or a sentence somebody
# actually said, and the only reliable way to guarantee that is to publish a
# library that was never a recording of anything.
#
# Listen reads `LISTEN_LIBRARY` when it is set, so this touches nothing in
# ~/Library/Application Support/Listen:
#
#   ./make_demo_library.sh
#   LISTEN_LIBRARY=/tmp/listen-demo LISTEN_DEMO_NAME=Alex \
#     Listen.app/Contents/MacOS/Listen
#
# A Finder launch inherits no shell environment, so the app has to be started
# from a terminal for the variable to be seen. That is the same reason
# `env -u HF_HOME` matters when testing model downloads.
set -e

DIR="${1:-/tmp/listen-demo}"
rm -rf "$DIR"
mkdir -p "$DIR/recordings" "$DIR/notes"

# The voices are macOS's own, so no human was recorded to make these files.
say_wav() {
    voice="$1"; text="$2"; out="$3"
    say -v "$voice" -o "$TMP/say.aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/say.aiff" "$out"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 - "$DIR" <<'PY'
import json, os, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone

root = sys.argv[1]
now = datetime.now(timezone.utc).replace(microsecond=0)

# Invented people, invented companies, invented conversations.
MEETINGS = [
    ("Weekly with Priya", "com.google.Chrome", 0, 12, [
        ("Me", "Priya Raman", [
            "Right, shall we start with the onboarding numbers?",
            "Sixty one percent finish the second step. It was forty four last month.",
            "That is the copy change then. Do we roll it out to everyone?",
            "I would give it another week. The sample is still small.",
            "Fine. Let us decide on Thursday with a fortnight behind it.",
            "One more thing, the trial length. Fourteen days is too short for teams.",
            "Agreed. Twenty one, and we say so on the pricing page.",
        ]),
    ]),
    ("Design review, mobile", "us.zoom.xos", 1, 27, [
        ("Me", "Tomas Lindqvist", [
            "The new layout puts the filter above the list rather than inside it.",
            "That is better. The old one hid the filter until you scrolled.",
            "It costs a row of height on a small phone, though.",
            "Worth it. A filter nobody can see is a list with things missing from it.",
            "Then I will take the same approach on the desktop side.",
        ]),
    ]),
    ("Kickoff: Northwind migration", "com.microsoft.teams2", 3, 41, [
        ("Me", "Aisha Bello", [
            "They want to be off the old system before the end of the quarter.",
            "That is nine weeks. The data export alone took three last time.",
            "We can run both in parallel for a month and cut over on a Friday.",
            "Then the risk is reconciliation rather than downtime, which I prefer.",
            "I will write it up and send it round before Wednesday.",
        ]),
    ]),
    ("Catch-up with Priya", "com.google.Chrome", 8, 19, [
        ("Me", "Priya Raman", [
            "The trial change went out on Monday.",
            "And already the support load is down, which I did not expect.",
            "People were writing in to ask for an extension. Now they do not need to.",
            "So the ticket volume was a pricing problem wearing a support hat.",
        ]),
    ]),
    ("Interview: staff engineer", "com.apple.FaceTime", 11, 46, [
        ("Me", "Marcus Whitfield", [
            "Tell me about something you shipped that you would build differently now.",
            "A search index we did not need. The data fitted in memory the whole time.",
            "What made you keep it?",
            "Nobody measured until a year in. By then it was load bearing.",
        ]),
    ]),
]

VOICES = {"Me": "Daniel", "default": ["Karen", "Alex", "Serena", "Fred", "Moira"]}

def wav(voice, text, out):
    with tempfile.TemporaryDirectory() as tmp:
        aiff = os.path.join(tmp, "s.aiff")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                        aiff, out], check=True)

for index, (title, app, days_ago, minutes, casts) in enumerate(MEETINGS):
    started = now - timedelta(days=days_ago, hours=index, minutes=7 * index)
    rid = started.astimezone().strftime("%Y-%m-%d-%H%M%S") + "-%04X" % (0xA000 + index)
    folder = os.path.join(root, "recordings", rid)
    os.makedirs(folder, exist_ok=True)

    mine, theirs, lines = casts[0]
    other_voice = VOICES["default"][index % len(VOICES["default"])]

    # Two tracks, as a real recording has: the microphone is the user and the
    # system track is everyone else. Both are synthesised speech.
    mine_text = " ".join(lines[0::2])
    their_text = " ".join(lines[1::2])
    wav(VOICES["Me"], mine_text, os.path.join(folder, "mic.wav"))
    wav(other_voice, their_text, os.path.join(folder, "system.wav"))

    segments, turns = [], []
    clock = 2.0
    for i, line in enumerate(lines):
        speaker = "Me" if i % 2 == 0 else theirs
        length = max(2.5, len(line) * 0.062)
        segments.append({"start": round(clock, 2), "end": round(clock + length, 2),
                         "speaker": speaker, "text": line})
        turns.append({"start": round(clock, 2), "end": round(clock + length, 2),
                      "speaker": speaker, "text": line})
        clock += length + 0.6

    json.dump({
        "id": rid, "title": title,
        "recorded_at": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration": round(minutes * 60 + 13.0, 2),
        "source": "detected", "state": "done",
        "app_bundle_id": app,
    }, open(os.path.join(folder, "metadata.json"), "w"), indent=1, sort_keys=True)

    json.dump({"segments": segments, "duration": round(minutes * 60 + 13.0, 2),
               "model": "mlx-community/parakeet-tdt-0.6b-v2",
               "wordLevel": False, "cleanup": {}, "dictionary": {}},
              open(os.path.join(folder, "transcript.json"), "w"), indent=1, sort_keys=True)
    json.dump(turns, open(os.path.join(folder, "turns.json"), "w"), indent=1, sort_keys=True)
    print(rid, title)

ids = sorted(os.listdir(os.path.join(root, "recordings")), reverse=True)
stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def note(slug, title, source, body, recordings, prompt=None):
    head = ['---', 'title: "%s"' % title, "created: " + stamp, "updated: " + stamp,
            "source: " + source]
    if prompt:
        head.append('prompt: "%s"' % prompt)
    head.append("recordings: [%s]" % ", ".join('"%s"' % r for r in recordings))
    head += ["---", ""]
    open(os.path.join(root, "notes", slug + ".md"), "w").write(
        "\n".join(head) + body.strip() + "\n")

note(ids[0] + "-yours", "Your notes", "you",
     "Trial length is the real lever here, not the copy change.\n\n"
     "Ask Priya for the cohort split before Thursday.", [ids[0]])

note(ids[2] + "-yours", "Your notes", "you",
     "They are more worried about reconciliation than about downtime.\n"
     "Lead with that in the write-up.", [ids[2]])

note("what-changed-with-onboarding", "What changed with onboarding", "agent",
     "Completion of the second onboarding step moved from 44% to 61% after the\n"
     "copy change, measured across two conversations three weeks apart.\n\n"
     "## Decided\n\n"
     "1. Trial goes from fourteen days to twenty one, said plainly on pricing.\n"
     "2. Roll-out held one more week for a larger sample.\n\n"
     "## Still open\n\n"
     "- Whether the support drop is the trial change or the copy change. Both\n"
     "  shipped the same week.\n",
     [ids[0], ids[3]],
     prompt="what actually changed with onboarding across these calls")

note("northwind-plan", "Northwind, the plan as it stands", "agent",
     "Nine weeks to be off the old system. The export took three weeks last\n"
     "time, so the plan runs both in parallel for a month and cuts over on a\n"
     "Friday.\n\n"
     "> Then the risk is reconciliation rather than downtime, which I prefer.\n\n"
     "Write-up due before Wednesday.\n",
     [ids[2]],
     prompt="summarise the Northwind kickoff")
PY

echo
echo "demo library at $DIR"
echo "run it with:  LISTEN_LIBRARY=$DIR LISTEN_DEMO_NAME=Alex Listen.app/Contents/MacOS/Listen"
