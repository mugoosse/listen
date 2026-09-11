#!/usr/bin/env python3
"""Exercise the built app, real local embeddings, CLI and MCP over synthetic data.

No personal library, provider credentials or network model calls. The stub speaks
the same Claude stream as Ask; validation, persistence and retrieval are real.
Set LISTEN_CONTEXT_KEEP=1 to retain the isolated app and library for UI checks.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix="listen-context-verify-"))
APP = WORK / "ContextTest.app"
LIB = WORK / "library"
DOMAIN = "com.mgo.listen-context-" + WORK.name.rsplit("-", 1)[1]
checks = 0


def check(condition, description):
    global checks
    assert condition, description
    checks += 1
    print("  ok:", description, flush=True)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2))


def recording(rid, title, speaker, text, date="2026-09-04T10:00:00Z"):
    folder = LIB / "recordings" / rid
    turns = [{"start": 0.0, "end": 30.0, "speaker": speaker, "text": text}]
    write(folder / "metadata.json", dict(id=rid, title=title, recorded_at=date,
          duration=30, source="imported", state="done", tags=["work"]))
    write(folder / "turns.json", turns)
    write(folder / "transcript.json", dict(segments=turns, duration=30,
          model="fixture", wordLevel=False, cleanup={}, dictionary={}))
    return folder


STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
a = sys.argv[1:]
if a and a[0] == "--version": print("2.1.226 (Claude Code)"); sys.exit()
if a and a[0] == "auth": print('{"loggedIn":true}'); sys.exit()
model = a[a.index("--model") + 1] if "--model" in a else "sonnet"
print(json.dumps({"type":"system","subtype":"init","session_id":"context-fixture","model":model}), flush=True)
text = a[a.index("--print") + 1] if "--print" in a else "{}"
if text == ".": sys.exit()
mode = Path(os.environ["CONTEXT_MODE"]).read_text().strip()
with open(os.environ["CONTEXT_CALLS"], "a") as f:
    f.write(json.dumps({"text":text,"args":a}) + "\n")
if mode == "slow": time.sleep(10)
payload = json.loads(text)
if isinstance(payload, list):
    if payload and "predicate" in payload[0]:
        out = {"operations":[]}
        if mode == "temporal":
            old = next((x for x in payload if x["predicate"] == "role"), None)
            change = next((x for x in payload if x["predicate"] == "decision"), None)
            if old and change:
                out["operations"] = [dict(operation="supersedes", prior=old["id"], next=change["id"], supports=[change["id"]], effectiveDate="2026-02-12", quote=change["evidence"]["quote"])]
    else:
        prose = [c for c in payload if c.get("category") not in ["works_on", "works_at", "collaborates_with"]]
        out = {"sentences":[{"text":c["text"],"claims":[c["id"]]} for c in prose[:2]]}
else:
    facts, relations = [], []
    for p in payload["passages"]:
        quote = p["text"][:400]
        person = p.get("speaker") if p.get("speaker") in payload["people"] else next((x for x in payload["people"] if x in quote), payload["people"][0])
        attribute = "role" if "designer" in quote or "director" in quote or "editor" in quote else "project"
        if "prefers" in quote: attribute = "preference"
        if "lead the Atlas" in quote: value = "Leads the Atlas project and is hiring a software developer."
        else: value = quote
        facts.append(dict(person=person,attribute=attribute,value=value,ref=p["ref"],quote=quote))
        if "lead the Atlas" in quote:
            relations.append(dict(person=person,attribute="works_on",value="Atlas",objectKind="project",ref=p["ref"],quote=quote))
        if "collaborate with Ben Ortiz" in quote and "Ben Ortiz" not in payload.get("reviewedAliases",{}).get(person,[]):
            relations.append(dict(person=person,attribute="collaborates_with",value="Ben Ortiz",objectKind="person",ref=p["ref"],quote=quote))
    if mode == "temporal":
        relations = []
        for fact in facts:
            if "handed Atlas" in fact["quote"]:
                fact["attribute"] = "decision"
                fact["time"] = {"from":"2026-02-12", "wording":"February 12, 2026", "precision":"day"}
            else: fact["attribute"] = "role"
    out = dict(facts=facts[:12],relations=relations[:8],reviewedRefs=[p["ref"] for p in payload["passages"]])
    if mode == "quote": out["facts"][0]["quote"] = "A quotation that never appeared in this recording."
    if mode == "person": out["facts"][0]["person"] = "Invented Stranger"
    if mode == "refs": out["reviewedRefs"] = []
    if mode == "attribute": out["facts"][0]["attribute"] = "personality_score"
    if mode == "target": out["relations"] = [dict(out["facts"][0],attribute="collaborates_with",value="Unknown Human",objectKind="person")]
    if mode == "unmentioned": out["relations"] = [dict(out["facts"][0],attribute="collaborates_with",value="Ben Ortiz",objectKind="person")]
    if mode == "repair" and "validationFeedback" not in payload:
        out["relations"] = [dict(out["facts"][0],attribute="works_on",value="Invented Project",objectKind="project")]
body = "not valid JSON" if mode == "malformed" else json.dumps(out)
print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":body}]}}), flush=True)
print(json.dumps({"type":"result","subtype":"success","is_error":False,"duration_ms":1,"total_cost_usd":0}), flush=True)
'''


def ui(binary, environment, library, person, claim):
    """The two screens the worklist reaches, driven through accessibility.

    Only under `--ui`, because it needs an unlocked screen and Accessibility
    permission for this terminal, and because everything above it is the half
    that has to pass on a build machine.

    The app copy is the one `main` already made under its own bundle identifier,
    so the real preferences and the real library are never touched.
    """
    probe = ROOT / ".xcbuild/tools/axprobe"
    if not probe.exists():
        probe.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(ROOT / "tools/axprobe.swift"), "-o", str(probe)], check=True)
    # Detection off, or the copy records the room in the middle of the test.
    subprocess.run(["defaults", "write", DOMAIN, "autoDetectMeetings", "-bool", "false"], check=True)

    proposed = claim["text"] + " Proposed by an agent."
    request = dict(jsonrpc="2.0", id=1, method="tools/call", params=dict(
        name="suggest_context_correction",
        arguments={"claim_id": claim["id"], "text": proposed, "why": "The source says so."}))
    subprocess.run([str(binary), "mcp"], input=json.dumps(request) + "\n",
                   env=environment, text=True, capture_output=True, timeout=60)

    def texts(app):
        out = subprocess.run([str(probe), "texts", str(app.pid)], capture_output=True, text=True)
        # 3 is no Accessibility permission, 4 an empty tree, which is what a
        # sleeping display gives back: every assertion below would pass on
        # nothing. See the axprobe note in CLAUDE.md.
        if out.returncode in (3, 4):
            return None
        return out.stdout

    def drive(panel, marker, seconds=25):
        """Launch, then poll the tree until `marker` is on it.

        Polling rather than one long wait, because how long the window takes is
        a property of the machine: this runs straight after the headless half
        has spent a minute in the same process, and a fixed 7 seconds reported a
        sleeping display on a Mac that was merely busy. Reading the tree is the
        one thing here that is safe to repeat.
        """
        app = subprocess.Popen([str(binary)], env=dict(environment, LISTEN_PANEL=panel),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + seconds
        dump = None
        while time.time() < deadline:
            time.sleep(2)
            dump = texts(app)
            if dump is None or marker in dump:
                break
        return app, dump

    app, dump = drive("person:" + person, "Summary")
    if dump is None:
        app.kill()
        print("  SKIP: no Accessibility permission, or an empty tree", flush=True)
        return
    # **The window has to prove it is there before anything below is believed.**
    # A sleeping display leaves the application element in the tree with no
    # window under it, which is not an empty tree and would fail every assertion
    # here for a reason that has nothing to do with the row. Past that line a
    # missing row is a failure, not a skip.
    if "Summary" not in dump:
        app.kill()
        print("  SKIP: the person page is not readable (is the display asleep?)", flush=True)
        return
    check("Suggested correction" in dump, "the person page shows what an agent proposed")
    check(proposed in dump, "with the wording it proposed")
    check("The source says so." in dump, "and why, which is what the reader decides on")
    subprocess.run([str(probe), "press", str(app.pid), "Accept"], capture_output=True)
    time.sleep(3)
    after = texts(app) or ""
    check(proposed in after and "Suggested correction" not in after,
          "Accept applies it and the row goes")
    check("Your correction" in after, "and the claim reads as one the user corrected")
    app.kill(); time.sleep(1)

    # A second proposal, so the pane has something to count.
    request["params"]["arguments"]["text"] = claim["text"] + " Again."
    subprocess.run([str(binary), "mcp"], input=json.dumps(request) + "\n",
                   env=environment, text=True, capture_output=True, timeout=60)
    app, found = drive("settings:People & Memory", "People & Memory")
    dump = found or ""
    if "People & Memory" not in dump:
        app.kill()
        print("  SKIP: the settings pane is not readable", flush=True)
        return
    check("suggested correction" in dump,
          "People & Memory says a correction is waiting")
    check(person in dump,
          "and names whose page to open rather than only counting")
    app.kill()


def main():
    built = Path(os.environ.get("LISTEN_APP", str(ROOT / "Listen.app")))
    assert (built / "Contents/MacOS/Listen").exists(), "Build and bundle Listen first."
    subprocess.run(["cp", "-cR", str(built), str(APP)], check=True)
    info = APP / "Contents/Info.plist"
    data = plistlib.loads(info.read_bytes())
    data["CFBundleIdentifier"] = DOMAIN
    info.write_bytes(plistlib.dumps(data))
    subprocess.run(["codesign", "--force", "--sign", "-", "--deep", str(APP)], check=True, capture_output=True)
    stub = WORK / "claude"
    stub.write_text(STUB)
    stub.chmod(0o755)
    (WORK / "mode").write_text("ok")
    for key, kind, value in [
        ("onboarded", "-bool", "true"), ("askEnabled", "-bool", "true"),
        ("agentPath_claude", "-string", str(stub)),
        ("agentPath_codex", "-string", "/nonexistent/codex"),
        ("agentProviders", "-data", "5b5d"),
    ]:
        subprocess.run(["defaults", "write", DOMAIN, key, kind, value], check=True)
    env = dict(os.environ, LISTEN_LIBRARY=str(LIB), LISTEN_NO_KEYCHAIN="1", LISTEN_NO_TELEMETRY="1",
               SHELL="/usr/bin/false", CONTEXT_MODE=str(WORK / "mode"), CONTEXT_CALLS=str(WORK / "calls.jsonl"))
    binary = APP / "Contents/MacOS/Listen"

    def run(*args, ok=True, as_json=False, custom_env=None):
        result = subprocess.run([str(binary), *args], env=custom_env or env, text=True, capture_output=True, timeout=120)
        if ok:
            assert result.returncode == 0, (args, result.stdout, result.stderr)
        else:
            assert result.returncode != 0, (args, "unexpected success", result.stdout)
        return json.loads(result.stdout) if as_json else result

    def calls():
        path = WORK / "calls.jsonl"
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def mcp(name, args, allowed=None, custom_env=None):
        argv = [str(binary), "mcp"] + (["--tools", allowed] if allowed else [])
        request = dict(jsonrpc="2.0", id=1, method="tools/call", params=dict(name=name, arguments=args))
        r = subprocess.run(argv, input=json.dumps(request) + "\n", env=custom_env or env, text=True, capture_output=True, timeout=60)
        return json.loads(r.stdout)["result"]

    old = recording("2026-08-01-alice", "First conversation", "Alice Rivera", "I work as a designer at Northstar.", "2026-08-01T10:00:00Z")
    recent = recording("2026-09-04-alice", "Atlas hiring", "Alice Rivera",
        "I lead the Atlas project and collaborate with Ben Ortiz. We are hiring a software developer.")
    recording("2026-09-04-unknown", "Waiting for a name", "A", "I manage the secret Moonshot project.")
    recording("2026-09-04-cat", "Cat sitting", "Ben Ortiz", "The cat sleeps on the sofa.")
    write(LIB / "contacts.json", {"version":1,"contacts":[
        {"name":"Charlie Stone","emails":["charlie@example.test"],"notes":"Charlie Stone is a technical editor."},
        {"name":"Al","emails":["al@example.test"]},
    ]})
    (LIB / "notes").mkdir()
    note = LIB / "notes" / "follow-ups.md"
    note.write_text("Alice Rivera prefers written follow-ups. Already agreed to keep them brief.")

    status = run("context", "status", "--json", as_json=True)
    check(status["waitingForNames"] == 1 and status["pending"] == 5, "ready sources and unknown speakers are distinguished")
    report = run("context", "update", "--claude", "--limit", "100", "--json", as_json=True)
    check(report["processed"] == 5 and report["failed"] == 0 and report["pending"] == 0, "recordings, unlinked mentions and contact notes are processed")
    alice = run("context", "history", "Alice Rivera", "--json", as_json=True)
    check(len(alice["facts"]) == 3 and len(alice["relations"]) == 2 and alice["summary"], "person gets a summary, facts and resolved relationships")
    check(all(item["evidence"] and item["evidence"][0]["quote"] for item in alice["facts"] + alice["relations"]), "every claim retains exact source evidence")
    check(not run("context", "history", "Al", "--json", as_json=True)["facts"], "Al does not match inside Already or Alice")
    before = len(calls())
    run("context", "update", "--claude", "--limit", "100")
    check(len(calls()) == before, "an unchanged library makes no LLM requests")
    extraction = next(c for c in calls() if isinstance(json.loads(c["text"]), dict))
    config = extraction["args"][extraction["args"].index("--mcp-config") + 1]
    check(json.loads(config) == {"mcpServers":{}}, "background extraction starts without library MCP tools")

    search = run("context", "search", "finding new staff", "--json", as_json=True)
    check(any(m["match"] == "semantic" and any(e["source"] == "rec:2026-09-04-alice" for e in m["evidence"]) for m in search["matches"]), "local embeddings retrieve a recruitment paraphrase without shared words")
    check(not any(any(e["source"] == "rec:2026-09-04-cat" for e in m["evidence"]) for m in search["matches"]), "unrelated cat passage stays out of recruitment results")
    unknown = run("context", "search", "Moonshot", "--json", as_json=True)
    unnamed_matches = [m for m in unknown["matches"] if any(e["source"] == "rec:2026-09-04-unknown" for e in m["evidence"])]
    check(unnamed_matches and all(m["kind"] == "passage" for m in unnamed_matches), "unnamed speech is searchable but never becomes a person fact")
    people = json.loads(mcp("list_people", {})["content"][0]["text"])["people"]
    check({"Alice Rivera", "Ben Ortiz", "Charlie Stone"}.issubset({p["name"] for p in people}), "MCP lists people without voiceprints")
    returned = json.loads(mcp("get_person_context", {"person":"Alice Rivera"})["content"][0]["text"])
    packet = run("context", "person", "Alice Rivera", "--json", as_json=True)
    check(returned == packet, "MCP and CLI return the same person context")
    first = json.loads(mcp("get_person_context", {"person":"Alice Rivera", "limit":1})["content"][0]["text"])
    second = json.loads(mcp("get_person_context", {"person":"Alice Rivera", "limit":1, "offset":1})["content"][0]["text"])
    check(first["omitted"] > 0 and first["entries"][0]["id"] != second["entries"][0]["id"], "compact MCP pages advance without repeating a claim")
    scoped = json.loads(mcp("search_context", {"query":"finding new staff", "person":"Ben Ortiz"})["content"][0]["text"])
    check(all("Ben Ortiz" in m["people"] for m in scoped["matches"]), "semantic retrieval respects the person filter, including explicit mentions")
    dated = json.loads(mcp("search_context", {"query":"Atlas", "before":"2026-08-30"})["content"][0]["text"])
    check(not any(any(e["source"] == "rec:2026-09-04-alice" for e in m["evidence"]) for m in dated["matches"]), "semantic retrieval respects date bounds")
    second_mac = WORK / "second-mac"
    shutil.copytree(LIB, second_mac, ignore=shutil.ignore_patterns("context"))
    second_env = dict(env, LISTEN_LIBRARY=str(second_mac))
    call_count = len(calls())
    remote_hits = run("context", "search", "hiring", "--json", as_json=True, custom_env=second_env)
    portable_hits = [m for m in remote_hits["matches"] if m.get("memory")]
    check(portable_hits and portable_hits[0]["memory"]["entry"]["evidence"], "a second Mac searches synced memory before building a local index")
    check(len(calls()) == call_count, "searching a synced memory never invokes the extraction provider")
    remote_entities = run("context", "entities", "--json", as_json=True, custom_env=second_env)
    check(any(e["kind"] == "project" and e["name"] == "Atlas" for e in remote_entities), "synced project IDs are discoverable without a local extraction ledger")
    claim = portable_hits[0]["id"]
    correction = dict(id=claim, hidden=False, pinned=False, replacement="Designing the brand identity.", updated="2026-09-08T10:00:00Z")
    write(second_mac / "people-context-edits.json", {claim: correction})
    corrected_hits = run("context", "search", "brand identity", "--json", as_json=True, custom_env=second_env)
    check(any(m.get("memory", {}).get("entry", {}).get("corrected") and m["id"] == claim for m in corrected_hits["matches"]), "cross-device search returns a correction before reindexing")
    correction.update(hidden=True, updated="2026-09-08T10:00:01Z")
    write(second_mac / "people-context-edits.json", {claim: correction})
    hidden_hits = run("context", "search", "brand identity", "--json", as_json=True, custom_env=second_env)
    check(not any(m["id"] == claim for m in hidden_hits["matches"]), "a hidden synced claim disappears from search")
    shutil.rmtree(second_mac / "recordings" / "2026-09-04-alice")
    removed = run("context", "search", "hiring", "--json", as_json=True, custom_env=second_env)
    check(not any(e["source"] == "rec:2026-09-04-alice" for m in removed["matches"] for e in m["evidence"]), "deleted sources cannot leak through synced memory search")
    shutil.copytree(LIB, WORK / "preview-library")
    metadata = json.loads((recent / "metadata.json").read_text())
    metadata["title"] = "Atlas hiring, renamed"
    write(recent / "metadata.json", metadata)
    filing_calls = len(calls())
    run("context", "index")
    check(len(calls()) == filing_calls, "filing changes refresh metadata without requesting a model")
    filed = run("context", "history", "Alice Rivera", "--json", as_json=True)
    check(any(e["title"] == "Atlas hiring, renamed" for f in filed["facts"] for e in f["evidence"]), "filing changes preserve the sourced details and update their title")
    refusal = mcp("get_person_context", {"person":"Alice Rivera"}, allowed="list_people")
    check(refusal.get("isError") is True, "MCP enforces the caller's tool allowlist")

    project = run("context", "project", "Atlas", "--json", as_json=True)
    check(any(e["subjectName"] == "Alice Rivera" for e in project["entries"]), "project context contains its related person without reading transcripts")
    run("context", "alias", project["entity"], "Atlas launch")
    check(run("context", "project", "Atlas launch", "--json", as_json=True)["entity"] == project["entity"], "reviewed project alias preserves stable identity")
    tiny = run("context", "person", "Alice Rivera", "--budget", "500", "--json", as_json=True)
    check(tiny["estimatedTokens"] <= 500 and tiny["omitted"] > 0, "person retrieval respects a small output budget")
    original = next(f for f in alice["facts"] if f["attribute"] == "role")
    run("context", "correct", original["id"], "Alice advises the Northstar design team.")
    corrected = run("context", "history", "Alice Rivera", "--json", as_json=True)
    changed = next(f for f in corrected["facts"] if f["id"] == original["id"])
    check(changed["corrected"] and "advises" in changed["value"] and "designer" in changed["evidence"][0]["quote"], "user correction remains separate from original source wording")
    run("context", "pin", original["id"])
    check(next(f for f in run("context", "history", "Alice Rivera", "--json", as_json=True)["facts"] if f["id"] == original["id"])["pinned"], "pin survives rebuilding the local context index")
    with sqlite3.connect(LIB / "context/memory.sqlite") as db:
        receipts = {row[0]: json.loads(row[1]) for row in db.execute("SELECT id,payload FROM receipts")}
    legacy_lib = WORK / "legacy-library"
    write(legacy_lib / "context/memory.json", {"version":1,"receipts":receipts,"summaries":{}})
    write(legacy_lib / "context/dismissed.json", [original["id"]])
    legacy_env = dict(env, LISTEN_LIBRARY=str(legacy_lib))
    run("context", "status", "--json", custom_env=legacy_env)
    with sqlite3.connect(legacy_lib / "context/memory.sqlite") as db:
        migrated = db.execute("SELECT count(*) FROM receipts").fetchone()[0]
        overrides = [json.loads(row[0]) for row in db.execute("SELECT payload FROM overrides")]
    check(migrated == len(receipts) and any(x["hidden"] for x in overrides), "legacy JSON migration commits receipts and hidden details together")
    check(not (legacy_lib / "context/memory.json").exists(), "committed migration removes obsolete plaintext content copies")
    with sqlite3.connect(legacy_lib / "context/memory.sqlite") as db: db.execute("PRAGMA user_version=999")
    check("newer Listen" in run("context", "status", custom_env=legacy_env, ok=False).stderr, "newer database versions fail closed")

    # Edits invalidate immediately, before a sweep or a new model request.
    turns = json.loads((old / "turns.json").read_text())
    turns[0]["text"] = "I now work as a director at Northstar."
    write(old / "turns.json", turns)
    stale = run("context", "history", "Alice Rivera", "--json", as_json=True)
    check(not any("designer" in f["value"] for f in stale["facts"]) and stale["summary"] == [], "a changed source invalidates both its facts and the derived summary immediately")
    start = len(calls())
    run("context", "update", "--claude", "--limit", "100")
    updates = [json.loads(c["text"]) for c in calls()[start:] if isinstance(json.loads(c["text"]), dict) and "passages" in json.loads(c["text"])]
    check(len(updates) == 1 and updates[0]["title"] == "First conversation", "an edit reprocesses only the changed source")

    repaired = recording("2026-09-05-repair", "Evidence correction", "Alice Rivera", "I lead the Atlas project and collaborate with Ben Ortiz.")
    (WORK / "mode").write_text("repair")
    before = len(calls())
    result = run("context", "update", "--claude", "--limit", "100", "--json", as_json=True)
    attempts = [json.loads(c["text"]) for c in calls()[before:] if isinstance(json.loads(c["text"]), dict) and "passages" in json.loads(c["text"])]
    check(result["failed"] == 0 and len(attempts) == 2 and "validationFeedback" in attempts[1], "an unsupported relationship gets exactly one bounded correction attempt")
    repaired_memory = run("context", "history", "Alice Rivera", "--json", as_json=True)
    check(not any(r["value"] == "Invented Project" for r in repaired_memory["relations"]), "repair preserves the exact target evidence requirement")
    shutil.rmtree(repaired)
    concurrent_role = recording("2026-09-05-role", "Another role", "Alice Rivera", "I also work as an editor for a local journal.")
    (WORK / "mode").write_text("ok")
    run("context", "update", "--claude", "--limit", "100")
    temporal = run("context", "history", "Alice Rivera", "--json", as_json=True)
    roles = [f for f in temporal["facts"] if f["attribute"] == "role"]
    check(len(roles) == 2 and all(f["status"] == "recorded" for f in roles), "a later source does not supersede an earlier role without change evidence")
    check(len({f["evidence"][0]["date"] for f in roles}) == 2, "coexisting observations retain their distinct provenance dates")
    shutil.rmtree(concurrent_role)
    for mode in ["quote", "person", "refs", "attribute", "target", "unmentioned", "malformed"]:
        folder = recording("2026-09-06-invalid", "Validation probe", "Alice Rivera", "I have a concrete plan for a new prototype. " + mode)
        (WORK / "mode").write_text(mode)
        before = len(calls())
        failed = run("context", "update", "--claude", "--limit", "100", "--json", ok=False)
        data = json.loads(failed.stdout)
        check(data["failed"] > 0, mode + " proposal is rejected and remains pending")
        attempts = [json.loads(c["text"]) for c in calls()[before:] if isinstance(json.loads(c["text"]), dict) and "passages" in json.loads(c["text"])]
        check(len(attempts) == 2, mode + " repair is bounded even when the model repeats its mistake")
        memory = run("context", "history", "Alice Rivera", "--json", as_json=True)
        check(not any(any(e["source"] == "rec:2026-09-06-invalid" for e in f["evidence"]) for f in memory["facts"]), mode + " never appears as a saved fact")
    (WORK / "mode").write_text("ok")
    retry = run("context", "update", "--claude", "--retry", "--limit", "100", "--json", as_json=True)
    check(retry["failed"] == 0 and retry["pending"] == 0, "explicit retry recovers a quarantined source")
    check(not list((LIB / "context").glob("rejected-*.json")), "successful retry removes rejected output")

    alice = run("context", "history", "Alice Rivera", "--json", as_json=True)
    hidden = next(f for f in alice["facts"] if f["attribute"] == "preference")
    run("context", "dismiss", hidden["id"])
    check(not any(f["id"] == hidden["id"] for f in run("context", "history", "Alice Rivera", "--json", as_json=True)["facts"]), "hiding a claim removes it from person context")
    result = run("context", "search", "written follow-ups", "--json", as_json=True)
    check(not any(m["id"] == hidden["id"] for m in result["matches"]), "hidden claims stay out of semantic retrieval")
    note.unlink()
    check(not any(e["source"] == "note:follow-ups" for f in run("context", "history", "Alice Rivera", "--json", as_json=True)["facts"] for e in f["evidence"]), "deleting a note removes its evidence immediately")

    # All chunks, including the far end of a very long recording, are reviewed.
    long = recording("2026-09-07-long", "Long source", "Alice Rivera", ("I am working on the long review. " * 650) + "Final unique sentence about the lighthouse.")
    run("context", "update", "--claude", "--retry", "--limit", "100")
    with sqlite3.connect(LIB / "context/memory.sqlite") as db:
        stored = {"receipts": {row[0]: json.loads(row[1]) for row in db.execute("SELECT id,payload FROM receipts")}}
    long_receipts = [r for r in stored["receipts"].values() if r["source"]["id"] == "rec:2026-09-07-long"]
    check(len(long_receipts) >= 3 and all(r.get("failure") is None for r in long_receipts), "long recordings process every bounded batch")
    check(any("lighthouse" in p["text"] for c in calls() if isinstance((v := json.loads(c["text"])), dict) for p in v.get("passages", [])), "the last sentence is sent, never silently truncated")
    check(all(r["source"]["passages"] == [] for r in stored["receipts"].values()), "person retrieval stores compact receipts rather than duplicated transcripts")

    # One writer across processes, including a manual CLI update while the app runs.
    recording("2026-09-07-lock", "Lock probe", "Alice Rivera", "I am arranging next week's product review.")
    (WORK / "mode").write_text("slow")
    p = subprocess.Popen([str(binary), "context", "update", "--claude", "--limit", "1"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(1)
        blocked = run("context", "update", "--claude", ok=False)
        check("already being updated" in blocked.stderr, "a second process cannot race the extraction writer")
    finally:
        p.communicate(timeout=60)
        (WORK / "mode").write_text("ok")

    # A later import of an old recording must reconcile with a known handover.
    temporal_lib = WORK / "temporal-library"
    temporal_env = dict(env, LISTEN_LIBRARY=str(temporal_lib))
    def temporal_source(rid, text, date):
        d = temporal_lib / "recordings" / rid
        turns = [dict(start=0,end=30,speaker="Alex Redwood",text=text)]
        write(d / "metadata.json", dict(id=rid,title=rid,recorded_at=date,duration=30,source="imported",state="done"))
        write(d / "turns.json", turns)
        write(d / "transcript.json", dict(segments=turns,duration=30,model="fixture",wordLevel=False,cleanup={},dictionary={}))
        return d
    (WORK / "mode").write_text("temporal")
    handover_source = temporal_source("march", "I handed Atlas to Priya on February 12, 2026.", "2026-03-03T10:00:00Z")
    run("context", "update", "--claude", "--limit", "100", custom_env=temporal_env)
    temporal_source("january", "I lead Atlas.", "2026-01-10T10:00:00Z")
    run("context", "update", "--claude", "--limit", "100", custom_env=temporal_env)
    temporal_history = run("context", "history", "Alex Redwood", "--json", custom_env=temporal_env, as_json=True)
    ended = next(x for x in temporal_history["facts"] if x["attribute"] == "role")
    check(ended["status"] == "historical" and ended["time"]["to"] == "2026-02-12", "late-imported January role ends at the evidenced February handover")
    check(any(t.get("resolvedModel") and t["quote"].endswith("February 12, 2026.") for t in ended["transitions"]), "transition retains its source quote and actual reported model")
    january_context = run("context", "person", "Alex Redwood", "--as-of", "2026-01-20", "--json", custom_env=temporal_env, as_json=True)
    check(any(x["id"] == ended["id"] for x in january_context["entries"]), "historical retrieval includes the leadership before the handover")
    check(any(e["source"] == "rec:march" and "February 12, 2026" in e["quote"] for x in january_context["entries"] for e in x.get("changeEvidence", [])), "compact context includes the cited source of a temporal change")
    historical_search = run("context", "search", "Atlas", "--as-of", "2026-01-20", "--json", custom_env=temporal_env, as_json=True)
    check(any(x["id"] == ended["id"] and any(e["source"] == "rec:march" for e in x.get("memory", {}).get("entry", {}).get("changeEvidence", [])) for x in historical_search["matches"]), "CLI temporal search includes the original and change provenance")
    check(all(x["kind"] != "passage" for x in historical_search["matches"]), "effective-date search cannot mix in undated raw passages")
    shutil.rmtree(handover_source)
    invalidated = run("context", "person", "Alex Redwood", "--json", custom_env=temporal_env, as_json=True)
    check(any(x["id"] == ended["id"] and x["status"] == "needs_review" for x in invalidated["entries"]), "deleted handover cannot silently restore an earlier current lead")
    check(not invalidated["brief"], "deleted temporal premise clears its cached brief immediately")
    (WORK / "mode").write_text("ok")

    # Explicit identity changes preserve reviewed aliases and user intent.
    identity_lib = WORK / "identity-library"
    shutil.copytree(WORK / "preview-library", identity_lib)
    identity_env = dict(env, LISTEN_LIBRARY=str(identity_lib))
    run("context", "update", "--claude", "--limit", "100", custom_env=identity_env)
    before_identity = run("context", "person", "Alice Rivera", "--budget", "16000", "--json", custom_env=identity_env, as_json=True)
    identity_role = next(x for x in before_identity["entries"] if x["predicate"] == "role")
    run("context", "correct", identity_role["id"], "Alice advises the design team.", custom_env=identity_env)
    run("rename", "Alice Rivera", "Alicia Rivero", custom_env=identity_env)
    run("context", "update", "--claude", "--limit", "100", custom_env=identity_env)
    renamed = run("context", "person", "Alicia Rivero", "--budget", "16000", "--json", custom_env=identity_env, as_json=True)
    check(renamed["entity"] == before_identity["entity"], "People rename preserves the stable memory identity")
    check(any(x["corrected"] and x["id"] == identity_role["id"] for x in renamed["entries"]), "correction survives renaming and re-extraction")
    check(any(e["source"] == "note:follow-ups" for x in renamed["entries"] for e in x["evidence"]), "old-name note mentions remain attributed through a reviewed alias")
    ben = run("context", "person", "Ben Ortiz", "--budget", "16000", "--json", custom_env=identity_env, as_json=True)
    ben_claim = ben["entries"][0]
    run("context", "correct", ben_claim["id"], "This is the owner's corrected detail.", custom_env=identity_env)
    run("merge", "Ben Ortiz", "Alicia Rivero", custom_env=identity_env)
    run("context", "update", "--claude", "--limit", "100", custom_env=identity_env)
    merged_person = run("context", "person", "Alicia Rivero", "--budget", "16000", "--json", custom_env=identity_env, as_json=True)
    check(any(x["corrected"] and "owner's corrected" in x["text"] for x in merged_person["entries"]), "explicit People merge transfers corrections to the surviving identity")

    # Person consent is narrower than the participants in a selected recording.
    consent_lib = WORK / "consent-library"
    consent_env = dict(env, LISTEN_LIBRARY=str(consent_lib))
    shared = consent_lib / "recordings" / "shared-meeting"
    shutil.copytree(WORK / "preview-library" / "recordings" / "2026-09-04-alice", shared)
    metadata = json.loads((shared / "metadata.json").read_text()); metadata["id"] = "shared-meeting"
    write(shared / "metadata.json", metadata)
    turns = [dict(start=0, end=10, speaker="Alice Rivera", text="I lead the Atlas project."),
             dict(start=10, end=20, speaker="Ben Ortiz", text="My private Birch project launches tomorrow.")]
    write(shared / "turns.json", turns)
    write(shared / "transcript.json", dict(segments=turns, duration=20, model="fixture", wordLevel=False, cleanup={}, dictionary={}))
    before = len(calls())
    slug = run("context", "note", "--person", "Alice Rivera", "She prefers a short written follow-up.", custom_env=consent_env).stdout.strip()
    saved_note = consent_lib / "notes" / (slug + ".md")
    check(saved_note.exists() and "about_person:" in saved_note.read_text(), "a person note saves a stable about-person identity")
    check(len(calls()) == before, "saving a person note makes no LLM calls")
    check(not run("context", "status", "--json", custom_env=consent_env, as_json=True)["automatic"], "new person notes do not enable automatic memory")
    report = run("context", "update", "--person", "Alice Rivera", "--source", "rec:shared-meeting", "--claude", "--limit", "100", "--json", custom_env=consent_env, as_json=True)
    check(report["failed"] == 0 and report["pending"] == 0, "an explicitly selected person and recording complete")
    payloads = [json.loads(c["text"]) for c in calls()[before:]]
    extracts = [p for p in payloads if isinstance(p, dict) and "passages" in p]
    check(extracts and all(p["people"] == ["Alice Rivera"] for p in extracts), "a shared recording authorizes only the selected person")
    check(all("Birch" not in json.dumps(p) and "follow-up" not in json.dumps(p) for p in payloads), "other participant passages and unselected notes never reach the provider")
    ben = run("context", "person", "Ben Ortiz", "--json", custom_env=consent_env, as_json=True)
    check(not ben["entries"], "updating Alice does not generate Ben's memory")
    run("context", "update", "--person", "Alice Rivera", "--source", "note:" + slug, "--claude", "--limit", "100", custom_env=consent_env)
    alice = run("context", "person", "Alice Rivera", "--budget", "16000", "--json", custom_env=consent_env, as_json=True)
    note_entry = next(x for x in alice["entries"] if any(e["source"] == "note:" + slug for e in x["evidence"]))
    check(note_entry["attribution"] == "reported" and note_entry["evidence"][0]["speaker"] == "Me", "the owner's note retains reported attribution rather than impersonating its subject")
    before = len(calls())
    run("context", "update", "--person", "Alice Rivera", "--source", "note:" + slug, "--claude", "--limit", "100", custom_env=consent_env)
    check(len(calls()) == before, "an unchanged scoped note does not incur another generation")
    saved_note.write_text(saved_note.read_text().replace("---", "---\nexclude_from_ai: true", 1))
    alice = run("context", "person", "Alice Rivera", "--json", custom_env=consent_env, as_json=True)
    check(all(e["source"] != "note:" + slug for x in alice["entries"] for e in x["evidence"]), "excluding a processed note immediately revokes its generated evidence")
    request = dict(jsonrpc="2.0", id=1, method="tools/call", params=dict(name="read_note", arguments={"note":slug}))
    response = subprocess.run([str(binary), "mcp"], input=json.dumps(request) + "\n", env=consent_env, text=True, capture_output=True, timeout=60)
    check(json.loads(response.stdout)["result"].get("isError") is True, "MCP cannot read a known excluded note slug")
    found = run("context", "search", "written follow-up", "--json", custom_env=consent_env, as_json=True)
    check(all(e["source"] != "note:" + slug for m in found.get("matches", []) for e in m.get("evidence", [])),
          "and local semantic search stops returning that note's passages too")
    check(saved_note.exists() and "written follow-up" in saved_note.read_text(), "exclusion keeps the owner's original note")
    run("context", "update", "--person", "Ben Ortiz", "--source", "rec:shared-meeting", "--claude", "--limit", "100", custom_env=consent_env)
    run("context", "forget", "--person", "Alice Rivera", custom_env=consent_env)
    check(not run("context", "person", "Alice Rivera", "--json", custom_env=consent_env, as_json=True)["entries"], "deleting generated memory removes only that person's projection")
    check(run("context", "person", "Ben Ortiz", "--json", custom_env=consent_env, as_json=True)["entries"], "the other participant's independently generated memory survives")
    check(saved_note.exists() and shared.exists(), "deleting generated memory preserves notes and recordings")
    run("context", "update", "--person", "Alice Rivera", "--source", "rec:shared-meeting", "--claude", "--limit", "100", custom_env=consent_env)
    check(run("context", "person", "Alice Rivera", "--json", custom_env=consent_env, as_json=True)["entries"], "a new explicit request may rebuild memory after deletion")

    # The proposal channel. An agent may say a claim misreads its own source and
    # may not apply that, which is the same split `DictionarySuggestions` makes
    # and the reason this is a worklist rather than a write.
    alice = run("context", "person", "Alice Rivera", "--budget", "16000", "--json", custom_env=consent_env, as_json=True)
    claim = alice["entries"][0]
    proposed = claim["text"] + " Corrected by hand."
    result = mcp("suggest_context_correction", {"claim_id": claim["id"], "text": proposed,
                                                "why": "The source sentence says so."}, custom_env=consent_env)
    check(result.get("isError") is not True, "an agent may propose a correction to a claim")
    unchanged = run("context", "person", "Alice Rivera", "--budget", "16000", "--json", custom_env=consent_env, as_json=True)
    check(next(x for x in unchanged["entries"] if x["id"] == claim["id"])["text"] == claim["text"],
          "and proposing changes nothing in memory")
    waiting = run("context", "suggestions", "--json", custom_env=consent_env, as_json=True)
    check(len(waiting) == 1 and waiting[0]["claim"] == claim["id"] and waiting[0]["was"] == claim["text"],
          "the worklist carries the claim, what it says now and what is proposed")
    check(mcp("suggest_context_correction", {"claim_id": "0" * 64, "text": "x", "why": "y"},
              custom_env=consent_env).get("isError") is True,
          "a claim id that is in no card is refused rather than queued against nothing")
    run("context", "suggestions", "--accept", claim["id"], custom_env=consent_env)
    corrected = run("context", "person", "Alice Rivera", "--budget", "16000", "--json", custom_env=consent_env, as_json=True)
    entry = next(x for x in corrected["entries"] if x["id"] == claim["id"])
    check(entry["text"] == proposed and entry["corrected"],
          "accepting applies it through the same correction contract the window uses")
    check(not run("context", "suggestions", "--json", custom_env=consent_env, as_json=True),
          "and takes it off the worklist without remembering a refusal")
    second = corrected["entries"][1]
    mcp("suggest_context_correction", {"claim_id": second["id"], "text": second["text"] + " No.",
                                       "why": "Because."}, custom_env=consent_env)
    run("context", "suggestions", "--dismiss", second["id"], custom_env=consent_env)
    check(not run("context", "suggestions", "--json", custom_env=consent_env, as_json=True),
          "dismissing takes it off the worklist")
    check(mcp("suggest_context_correction", {"claim_id": second["id"], "text": second["text"] + " No.",
                                             "why": "Because."}, custom_env=consent_env).get("isError") is True,
          "and a claim the user has dismissed is never offered again")
    check((consent_lib / "context-suggestions.json").exists(),
          "the worklist is a file beside the library, like dictionary-suggestions.json")

    run("context", "auto", "on")
    elsewhere = dict(env, LISTEN_LIBRARY=str(WORK / "other-library"))
    check(not run("context", "status", "--json", custom_env=elsewhere, as_json=True)["automatic"], "automatic-processing consent does not follow a scratch library override")
    run("context", "auto", "off")
    run("context", "update", "--unknown", ok=False)
    check(True, "unknown CLI flags fail instead of silently changing the request")
    if "--ui" in sys.argv:
        # Ben rather than Alice: every one of her claims has been corrected or
        # has a dismissal remembered against it by now, and the UI section needs
        # one with neither. His memory was generated independently above, which
        # is what that assertion is for.
        ben = run("context", "person", "Ben Ortiz", "--budget", "16000",
                  "--json", custom_env=consent_env, as_json=True)
        check(bool(ben["entries"]), "the fixture has a claim the UI section can use")
        ui(binary, consent_env, consent_lib, "Ben Ortiz", ben["entries"][0])

    fixture_env = {k: env[k] for k in ["LISTEN_LIBRARY", "LISTEN_NO_KEYCHAIN", "LISTEN_NO_TELEMETRY", "SHELL", "CONTEXT_MODE", "CONTEXT_CALLS"]}
    (WORK / "environment.json").write_text(json.dumps({"binary":str(binary), "domain":DOMAIN, "environment":fixture_env}, indent=2))
    print(f"\n{checks} checks passed. Fixture: {WORK}", flush=True)


try:
    main()
finally:
    if not os.environ.get("LISTEN_CONTEXT_KEEP"):
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
        # **And the file, because `defaults delete` alone does not remove it.**
        # One 42 byte plist was left in ~/Library/Preferences per run, and 42 of
        # them had accumulated before anybody looked. cfprefsd writes the file
        # back out for a domain the app has touched, so the delete lands and the
        # litter stays.
        Path("~/Library/Preferences").expanduser().joinpath(DOMAIN + ".plist").unlink(missing_ok=True)
        shutil.rmtree(WORK, ignore_errors=True)
    else:
        print("Retained fixture:", WORK, flush=True)
