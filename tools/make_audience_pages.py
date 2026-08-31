#!/usr/bin/env python3
"""Build the per-profession landing pages under docs/.

    python3 tools/make_audience_pages.py

Why these exist. The home page says "meeting" fifteen times and "call" eight,
and says client, patient, session, interview, privilege and consent not once.
That is the vocabulary of a generic knowledge worker, which is Granola's buyer,
and spec/01-product.md in the iPhone repository argues at length for a different
one: people whose conversations legally cannot go to somebody else's server.
A therapist does not have meetings. She has sessions, with clients.

So each page below is written in one profession's nouns, opens on the fear that
profession actually has, and answers the questions that profession actually
searches for.

Three rules held throughout, because this audience is the one that will notice:

  * No compliance claims. docs/hipaa.html sets the line already: there is no
    such thing as a HIPAA certification, and the software's job is to be
    deployable in a compliant configuration. Nothing here may claim more.
  * No legal advice. Recording law varies by country and by state, and every
    page says so and sends the reader to their own regulator or bar.
  * No absolutes we cannot keep. A page for journalists that implies source
    protection against a seized laptop would be worse than no page at all.
"""

import importlib.util
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(HERE, "docs")

_spec = importlib.util.spec_from_file_location(
    "channels", os.path.join(HERE, "tools", "make_channel_pages.py"))
channels = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(channels)


AUDIENCE_CSS = """
/* ---------- audience pages ---------------------------------------------- */

.who { display: grid; gap: 16px; margin: 32px 0 0;
       grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); }
.who a {
  display: block; text-decoration: none; padding: 22px 24px;
  border: 1px solid var(--rule); border-radius: 14px; background: var(--paper-warm);
  transition: border-color .15s ease, transform .15s ease;
}
.who a:hover { border-color: var(--ink-faint); transform: translateY(-1px); }
.who b {
  display: block; font-family: var(--serif); font-weight: 400; font-size: 21px;
  line-height: 1.25; color: var(--ink); margin: 0 0 8px;
}
.who span { display: block; font-size: 15px; line-height: 1.5; color: var(--ink-soft); }

blockquote.said {
  margin: 34px 0 0; padding: 0 0 0 22px;
  border-left: 2px solid var(--blue);
}
blockquote.said p {
  font-family: var(--serif); font-size: 22px; line-height: 1.4;
  color: var(--ink); margin: 0;
}
"""


AUDIENCES = [
    {
        "slug": "for-therapists",
        "eyebrow": "For therapists and counsellors",
        "title": "Session notes that never leave your Mac | Listen",
        "h1": "Write up the session<br>without writing it up.",
        "sub": ("Listen records a session on your own Mac, writes it down and "
                "works out who said what. There is no server it could be sent "
                "to, because there are no servers."),
        "said": "I can be with the client, and the notes are waiting when we finish.",
        "problem_head": "The notes cost you the hour.",
        "problem": (
            "You are either present with somebody or you are writing about "
            "them. Most of the tools built to solve that send the session to a "
            "company's servers, which is the one thing this work does not allow: "
            "a client's disclosures become somebody else's data, held under "
            "somebody else's retention policy, reachable by somebody else's "
            "subpoena."),
        "why_head": "Nothing to hold it but you.",
        "why": (
            "Listen has no account, no server and no support channel that "
            "touches your library. The recording, the transcript and the names "
            "on it are all made on your machine, so the obligations you already "
            "carry stay where they already are rather than being shared with a "
            "vendor you would then have to vet."),
        "points": [
            "Voiceprints are biometric data, GDPR Article 9, and yours never leave the Mac",
            "iCloud sync is off by default, and can be forced off for good",
            "Ask a question about a session with a model running on the same machine",
            "Sessions are ordinary folders you can move, archive or delete",
        ],
        "obligation": (
            "<strong>Consent is yours to get, and it is not a formality here.</strong> "
            "Listen has no way to tell a client anything, so the conversation "
            "before the recorder goes on is entirely between you and them. Your "
            "professional body almost certainly has a position on recording "
            "sessions, and in many places the law does too. Follow those, not "
            "this page."),
        "faq": [
            ("Can I record therapy sessions with this?",
             "Listen records and transcribes on your own Mac, which removes the "
             "vendor from the question. Whether you may record a given session, "
             "and on what terms, is set by your professional body, your "
             "insurer and the law where you practise."),
            ("Does the session audio go anywhere for transcription?",
             "No. Transcription runs on your Mac's own chip. There is no upload "
             "step, and it works with the network off."),
            ("Is this HIPAA compliant?",
             "No software is: HHS recognises no certifying body, and compliance "
             "describes how you deploy something rather than what it is. What "
             "Listen can do is be deployed in a compliant configuration, and "
             "the HIPAA page sets out exactly what that configuration is."),
            ("What about supervision?",
             "The transcript is a plain file you own, so taking an excerpt to "
             "supervision is a copy and paste rather than an export from a "
             "service. What you may share is a question for your supervisor and "
             "your client's consent, not for the software."),
            ("Can I delete a session completely?",
             "Yes. A recording is one folder, and deleting it in Finder is a "
             "supported operation rather than a way to corrupt an index. If "
             "backups are on, copies age out of ~/Backups/Listen, and `listen "
             "backup` says what is there."),
            ("Does it work with sessions over video?",
             "Yes, and it does not join the call. It records the audio your Mac "
             "is playing along with your microphone, so the client sees the "
             "session they expected and nothing else."),
        ],
    },
    {
        "slug": "for-coaches",
        "eyebrow": "For coaches and consultants",
        "title": "Record client calls and remember every one | Listen",
        "h1": "They are paying for<br>your attention.",
        "sub": ("Listen records the call on your own Mac and writes it up "
                "there, so the hour goes to the person who booked it. Nothing "
                "joins the call, and nothing is uploaded anywhere."),
        "said": "I stopped taking notes and started listening again. The write-up is waiting when we hang up.",
        "problem_head": "Nobody books you to watch you type.",
        "problem": (
            "An hour of coaching is an hour of attention, and attention is the "
            "thing being bought. Every minute spent writing is a minute the "
            "client paid for and did not get, and the notes you manage to take "
            "are the ones you could catch rather than the ones that mattered. "
            "Then a fortnight later somebody refers back to a decision and you "
            "are reconstructing it from memory."),
        "why_head": "The hour is theirs. The record writes itself.",
        "why": (
            "Listen records the call and writes it up on your own machine, with "
            "names on the turns, and remembers voices between calls. So the "
            "person you speak to every other Tuesday names themselves after the "
            "first time, and what they said in March is a search away rather "
            "than a memory. None of it goes to anybody's server, which matters "
            "more here than it looks: people tell a coach things they have not "
            "told anybody, and the relationship runs entirely on that."),
        "points": [
            "Read every call you have had with somebody just before you get on the next one",
            "Ask what they said about a goal three months ago and click through to the moment",
            "Works on WhatsApp and Zoom alike, because nothing joins the call",
            "Your history is a folder you own, so nothing expires when a plan does",
        ],
        "obligation": (
            "<strong>Tell them you are recording.</strong> In some places it is "
            "the law and in the rest it is simply the job: a coaching "
            "relationship is built on somebody trusting you with what they "
            "actually think. Asking first costs one sentence, and being the "
            "person who asked is worth more than the recording."),
        "faq": [
            ("Can I record coaching calls on my Mac?",
             "Yes. Listen records your microphone and the audio your Mac is "
             "playing, so it captures both sides of a call in any app, and "
             "writes the transcript on the same machine."),
            ("Do I have to tell the client?",
             "Legally it depends where you both are, and practically the answer "
             "is always yes. Listen has no way to tell them, and a client who "
             "finds out afterwards is a client you have lost."),
            ("Does the recording go to a company?",
             "No. There is no Listen server and no account. The audio and the "
             "transcript are files in a folder on your own disk."),
            ("Can I look up what somebody said months ago?",
             "Yes, and it is the part most people end up relying on. Every "
             "transcript is searchable offline, and you can ask a question "
             "across all of them and click a reference through to the recording "
             "it came from."),
            ("Does it recognise the same client each time?",
             "Name somebody once and Listen suggests them the next time it "
             "hears that voice. Suggestions are ranked and never applied on "
             "their own."),
            ("Can I keep clients separate?",
             "Tag each recording with the client and filter to one. For a "
             "harder separation, LISTEN_LIBRARY points the app at a different "
             "library folder entirely."),
            ("What does it cost?",
             "The Mac app is free to download and open source under the AGPL, "
             "which is what stops the code itself ever being closed. Your "
             "recordings and transcripts are files on your own disk, so nothing "
             "you have already recorded can be moved behind a plan later."),
        ],
    },
    {
        "slug": "for-lawyers",
        "eyebrow": "For lawyers",
        "title": "Record client calls without a third party | Listen",
        "h1": "A record of the call,<br>held by nobody else.",
        "sub": ("Listen records client calls on your own Mac and writes them "
                "up there. No bot in the call, no account, and no vendor "
                "holding privileged material."),
        "said": "There is no third party. That is the entire reason I could use it.",
        "problem_head": "A vendor in the middle of a privileged call.",
        "problem": (
            "Every meeting notetaker worth the name works by putting something "
            "in the call and something else on a server. For most work that is "
            "an ordinary procurement question. For a call with a client it is a "
            "party you did not intend, holding material you did not intend to "
            "share, in a place a third party can be asked to produce it from."),
        "why_head": "Nothing to produce, because nobody else has it.",
        "why": (
            "Listen has no server. The recording, the transcript and the "
            "speaker names are made on your machine and stay there, so there is "
            "no vendor to serve, no retention schedule but yours, and no "
            "account that could be compelled. Whether that changes your analysis "
            "is your call to make, and the architecture is set out plainly so "
            "you can make it."),
        "points": [
            "Nothing joins the call, so the attendee list is exactly who you invited",
            "Works on WhatsApp and Signal, where a bot cannot go at all",
            "Tag by matter, and search every call you have ever taken, offline",
            "Ask a question across matters with a model running on your own Mac",
        ],
        "obligation": (
            "<strong>Recording law varies, sharply.</strong> Some places need "
            "every party's consent and some need one, and the rule can change "
            "between neighbouring states. Listen has no way to notify anybody, "
            "so telling the other side is on you. Nothing on this page is legal "
            "advice, and your bar's guidance outranks it."),
        "faq": [
            ("Could a recording be subpoenaed from the maker of Listen?",
             "There is nothing to subpoena. Listen has no server, no account "
             "and no copy of your library, so a request would have to come to "
             "you, which is where your existing obligations already sit."),
            ("Does a notetaker in the call affect privilege?",
             "That is a question for you and your jurisdiction, and the reason "
             "the design avoids it: Listen puts nothing in the call and nothing "
             "on anybody's server, so the usual third-party analysis has no "
             "third party to consider."),
            ("Do I need everyone's consent to record?",
             "Often, and it depends entirely on where you and they are. Listen "
             "cannot tell anybody it is running, so say so yourself, and follow "
             "your bar rather than this page."),
            ("Can I keep matters separate?",
             "Tag recordings by matter and filter to one. For a harder "
             "separation, LISTEN_LIBRARY points the app at an entirely "
             "different library folder."),
            ("Is there an audit trail?",
             "`listen activity` records every tool call, agent run, export, "
             "deletion and backup by name and id, never by content."),
            ("Can my firm control the settings centrally?",
             "Yes. Standard managed preferences let IT force sync off, restrict "
             "questions to a model on the machine, turn dictation history off "
             "or redirect backups."),
        ],
    },
    {
        "slug": "for-clinicians",
        "eyebrow": "For doctors and clinicians",
        "title": "Record a consultation without sending PHI anywhere | Listen",
        "h1": "The consultation,<br>written up on your Mac.",
        "sub": ("Listen records a consultation and transcribes it on the same "
                "machine. No account, no upload, and no business associate to "
                "sign an agreement with."),
        "said": "No BAA to chase, because there is nobody to sign one with.",
        "problem_head": "Every vendor is another agreement.",
        "problem": (
            "Anything that touches protected health information on your behalf "
            "is a business associate, which means paperwork, diligence and a "
            "breach you are still answerable for. That is a heavy price for "
            "notes, and it is the reason so much of this work is still typed up "
            "after hours."),
        "why_head": "Nobody acts on your behalf.",
        "why": (
            "Listen's maker never creates, receives, maintains or transmits "
            "anything on your behalf. There is no server, no account and no "
            "support channel that touches your library, so the obligations stay "
            "where the data stays. The HIPAA page sets out the configuration "
            "and where each control lives in the code."),
        "points": [
            "Transcription runs on the Neural Engine, with the network off if you like",
            "iCloud sync off by default, and forceable off, because Apple signs no BAA",
            "Ask questions with a local model, which sends nothing anywhere",
            "Dictate notes anywhere on the Mac with the same speech model",
        ],
        "obligation": (
            "<strong>Recording a patient needs their agreement.</strong> Listen "
            "cannot ask for it and cannot record that you did. Your employer, "
            "your regulator and the law where you practise set the rule, and "
            "this page does not."),
        "faq": [
            ("Do I need a Business Associate Agreement?",
             "There is nobody to sign one with. Listen's maker never handles "
             "your data, so no business associate relationship is created. That "
             "is the architecture, not a promise about your compliance."),
            ("Is Listen HIPAA compliant?",
             "No product is, and any that claims to be is worth a second look: "
             "HHS recognises no certifying body. Listen can be deployed in a "
             "compliant configuration, and docs/hipaa.html is that "
             "configuration in full."),
            ("Can I use iCloud sync with PHI?",
             "The guide's answer is no. The sealing is real, but Apple does not "
             "sign BAAs for iCloud and HHS treats even a no-view host of "
             "ciphertext as a business associate. Sync is off by default and a "
             "device profile can force it off."),
            ("Can I ask an AI about a consultation?",
             "With a model running on the machine, yes, and nothing leaves it. "
             "A hosted provider is only appropriate under a BAA you hold with "
             "that provider."),
            ("Does it integrate with my EHR?",
             "No. Listen writes plain files you own, and moving anything into a "
             "record system is a deliberate copy you make."),
        ],
    },
    {
        "slug": "for-journalists",
        "eyebrow": "For journalists",
        "title": "Record and transcribe an interview offline | Listen",
        "h1": "The interview,<br>transcribed on your laptop.",
        "sub": ("Listen records an interview and writes it up on your own "
                "machine, with the network off if you want. No account, no "
                "upload, and no company holding your tape."),
        "said": "It works on a plane, and there is no company holding the tape.",
        "problem_head": "Your tape, on somebody else's disk.",
        "problem": (
            "Sending an interview to a transcription service puts a recording "
            "of your source in a company's hands: subject to that company's "
            "retention, its jurisdiction, its security, and any order served on "
            "it. You will usually never know it happened."),
        "why_head": "There is no company to serve.",
        "why": (
            "Listen has no server and no account. The recording and the "
            "transcript are files on your machine, made by your machine, so an "
            "order has to come to you, where whatever protection you have "
            "applies. It is open source under the AGPL, so this is checkable "
            "rather than claimed."),
        "points": [
            "Records and transcribes with the network off, on a plane or abroad",
            "Works on Signal and WhatsApp, where a notetaker bot cannot go",
            "Search every interview you have ever done, instantly and locally",
            "Correct a name or a sentence without re-transcribing anything",
        ],
        "obligation": (
            "<strong>This protects the tape from a vendor, not from everything."
            "</strong> A recording on your laptop is still a recording on your "
            "laptop: it can be seized, compelled or copied like anything else "
            "there. Full-disk encryption, what you keep and for how long, and "
            "how you agreed to treat a source are all still yours to get right. "
            "Removing the third party removes one risk, and it is worth being "
            "precise about which one."),
        "faq": [
            ("Does the audio get uploaded for transcription?",
             "No. It runs on your Mac's own chip, offline, which is also why it "
             "works on a plane and in places you would rather not upload from."),
            ("Can the recording be obtained from the maker of Listen?",
             "There is nothing to obtain. No server, no account, no copy."),
            ("Can I verify that, rather than trust it?",
             "Yes, and that is the reason for the licence. The source is public "
             "under the AGPL, and the security page names every connection the "
             "app can make and how to watch for it with a firewall tool."),
            ("What if my laptop is seized?",
             "Then the recordings on it are exposed, exactly as any other file "
             "would be. Listen removes the vendor from the picture. It does not "
             "and cannot protect a device you no longer control."),
            ("Does it work for phone interviews?",
             "If the call happens on your Mac, yes: WhatsApp, Signal, Telegram, "
             "FaceTime, Zoom and anything else that makes sound."),
            ("Can I keep a source's name out of it?",
             "Speakers are letters until you name them, and a name you do "
             "assign is stored only in your own library. Leaving one unnamed "
             "costs nothing."),
        ],
    },
    {
        "slug": "for-hr-investigations",
        "eyebrow": "For HR and workplace investigations",
        "title": "Record an investigation interview on your Mac | Listen",
        "h1": "An accurate record,<br>and a short circulation list.",
        "sub": ("Listen records an investigation interview on your own machine "
                "and writes it up there. Nothing joins the call, and the "
                "recording does not travel to a vendor."),
        "said": "The circulation list is me. That is the whole point.",
        "problem_head": "The fewer places it exists, the better.",
        "problem": (
            "An investigation interview is the most sensitive recording an "
            "employer ever makes: it names people, it decides outcomes, and it "
            "will be read back in a dispute. Every copy of it that exists "
            "somewhere you do not control is a copy somebody can ask for, and "
            "most notetakers make several."),
        "why_head": "One copy, on one machine.",
        "why": (
            "Listen records on the investigator's own Mac and writes the "
            "transcript there. There is no vendor holding employee statements, "
            "no account to administer and nothing added to the meeting that the "
            "person being interviewed has to be told about separately."),
        "points": [
            "Correct who said what without touching the words or the timings",
            "Every edit is yours; an agent may write notes and tags and nothing else",
            "`listen activity` logs each access by name and id, never by content",
            "Managed profiles let IT force sync off across the organisation",
        ],
        "obligation": (
            "<strong>Tell the person you are recording, and get their "
            "agreement.</strong> In much of Europe this is not optional, works "
            "councils may have a say, and employees have rights of access to "
            "what is held about them. Listen keeps the recording where you can "
            "answer those requests. It does not answer them for you, and it is "
            "not legal advice."),
        "faq": [
            ("Can we record investigation interviews with this?",
             "Listen records on the investigator's machine and keeps the file "
             "there. Whether you may record, and on what notice, is set by "
             "employment law where you operate and by your own policy."),
            ("Can an employee ask for a copy?",
             "They may well have a right to. The recording and transcript are "
             "plain files in a folder you control, so answering a request is a "
             "copy rather than an export request to a supplier."),
            ("Is there an audit trail?",
             "`listen activity` records every tool call, agent run, export, "
             "deletion and backup by name and id only, never by content, and "
             "that claim is asserted by a test rather than assumed."),
            ("Can IT lock the settings down?",
             "Yes, through the same device profiles you already use: sync off, "
             "questions answered only by a model on the machine, dictation "
             "history off, backups pointed wherever policy says."),
            ("Does anything appear in the meeting?",
             "No. Nothing joins and nothing is added to the participant list, "
             "which is why saying you are recording matters so much here."),
        ],
    },
]


def render(audience, others):
    faq_html = "\n".join(
        '        <details>\n'
        '          <summary>%s</summary>\n'
        '          <div class="answer"><p>%s</p></div>\n'
        '        </details>' % (channels.esc(q), channels.esc(a))
        for q, a in audience["faq"])

    faq_ld = json.dumps({
        "@context": "https://schema.org", "@type": "FAQPage",
        "mainEntity": [{"@type": "Question", "name": q,
                        "acceptedAnswer": {"@type": "Answer", "text": a}}
                       for q, a in audience["faq"]],
    }, indent=2)

    nav = "\n".join(
        '        <a href="%s.html"%s>%s</a>' % (
            o["slug"],
            ' aria-current="page"' if o["slug"] == audience["slug"] else "",
            channels.esc(o["eyebrow"].replace("For ", "")))
        for o in others)

    points = "\n".join("        <li>%s</li>" % channels.esc(p)
                       for p in audience["points"])

    desc = channels.esc(audience["sub"].replace("\n", " "))

    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Rybbit: self-hosted, cookieless, privacy-first page-view analytics.
     Guarded by hostname rather than a build flag, because this is static
     HTML with no build step: tools/serve_docs.py serves these same files
     for local preview, and that traffic must never land in the real count. -->
<script>
if (location.hostname === "mugoosse.github.io") {
  var s = document.createElement("script");
  s.defer = true;
  s.src = "https://cdn.zebralabs.org/api/script.js";
  s.setAttribute("data-site-id", "0c285fdaf9b0");
  document.head.appendChild(s);
}
</script>
<title>%(title)s</title>
<meta name="description" content="%(desc)s">
<link rel="canonical" href="https://mugoosse.github.io/listen/%(slug)s.html">
<link rel="icon" href="icon.png">
<meta property="og:title" content="%(title)s">
<meta property="og:description" content="%(desc)s">
<meta property="og:type" content="website">
<meta property="og:url" content="https://mugoosse.github.io/listen/%(slug)s.html">
<meta property="og:image" content="https://mugoosse.github.io/listen/social-preview.png">
<meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">
%(faq_ld)s
</script>
<style>%(css)s</style>
</head>
<body>

<div class="bar">
  <div class="page">
    <div class="bar-inner">
      <a class="bar-mark" href="index.html">
        <img src="icon.png" alt="">
        <span class="bar-name">Listen</span>
      </a>
      <span class="bar-spacer"></span>
      <a class="button small" href="index.html">How it works</a>
      <a class="button small primary" href="https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg" data-rybbit-event="mac_download_clicked" data-rybbit-prop-slot="nav">Download</a>
    </div>
  </div>
</div>

<header class="hero" id="top">
  <div class="page">
    <div class="col">
      <p class="eyebrow">%(eyebrow)s</p>
      <h1>%(h1)s</h1>
      <p class="hero-sub">%(sub)s</p>
    </div>

    <div class="buttons" id="buttons">
      <a class="button primary" href="https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg" data-rybbit-event="mac_download_clicked" data-rybbit-prop-slot="hero">Download for macOS</a>
      <a class="button" href="index.html">See everything it does</a>
    </div>
    <p class="under-button" id="under-button">Free and open source · Apple silicon · macOS 14 or later</p>

    <div class="chipcheck" id="chipcheck" hidden>
      <p><b>This looks like an Intel Mac, and Listen will not run on it.</b></p>
      <p>Listen transcribes on your own machine, and that needs the Neural
      Engine Apple introduced with the M1 in late 2020. There is no Intel
      version, and there is no version that would work.</p>
      <p>Open the Apple menu and choose About This Mac. If it says <b>Chip</b>
      rather than <b>Processor</b>, this guess is wrong and you can
      <a href="https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg" data-rybbit-event="mac_download_clicked" data-rybbit-prop-slot="intel-fallback">download
      Listen</a> as normal.</p>
    </div>
  </div>
</header>

<section id="problem">
  <div class="page">
    <div class="col">
      <p class="eyebrow">The problem</p>
      <h2>%(problem_head)s</h2>
      <p class="lead">%(problem)s</p>
      <blockquote class="said"><p>%(said)s</p></blockquote>
      <p class="legal">Written as the buyer describes it. Not yet a quote from a
      named user, and it is not presented as one.</p>
    </div>
  </div>
</section>

<section id="why">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Why this one</p>
      <h2>%(why_head)s</h2>
      <p class="lead">%(why)s</p>
      <ul class="points">
%(points)s
      </ul>
      <div class="consent">
        <p>%(obligation)s</p>
      </div>
    </div>
  </div>
</section>

<section id="after">
  <div class="page">
    <div class="col">
      <p class="eyebrow">After the conversation</p>
      <h2>Never listen to it twice.</h2>
      <p class="lead">Give it your attention, not your notepad. Listen writes it
      up on your Mac's own chip, works out who spoke, and remembers the voices,
      so the people you see often name themselves after the first time.</p>
      <p><a href="index.html">See everything Listen does →</a></p>
    </div>
  </div>
</section>

<section id="privacy">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Privacy</p>
      <h2>Your recordings stay yours.</h2>
      <p class="lead">There is no Listen server, because there are no servers.
      No account, and nothing you record ever reports back.</p>
      <p>Listen is open source under the AGPL, so none of that has to be taken
      on trust. <a href="security.html">What runs where</a> sets out every
      connection it can make and how to check each one yourself, and there are
      answers ready for a <a href="privacy.html">privacy</a> or
      <a href="hipaa.html">HIPAA</a> review.</p>
    </div>
  </div>
</section>

<section id="faq">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Questions</p>
      <h2>%(faq_head)s</h2>
      <div class="faq">
%(faq)s
      </div>
    </div>
  </div>
</section>

<section id="get">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Get Listen</p>
      <h2>Try it on your next one.</h2>
      <p class="lead">Free to download, and open source. Apple silicon, macOS
      14 or later. The speech model is about 2.5 GB and downloads once, the first
      time you run it.</p>
      <div class="buttons">
        <a class="button primary" href="https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg" data-rybbit-event="mac_download_clicked" data-rybbit-prop-slot="footer">Download for macOS</a>
        <a class="button" href="https://github.com/mugoosse/listen">Read the source</a>
      </div>

      <p class="eyebrow" style="margin-top:44px">Written for</p>
      <div class="channel-nav">
%(nav)s
      </div>

      <p class="legal">Nothing on this page is legal, clinical or professional
      advice. Recording law and professional duties vary by country and by
      state, and yours outrank anything written here.</p>
    </div>
  </div>
</section>

<footer>
  <div class="page">
    <p>Made by <a href="https://maxgoespublic.com/">Maxime Goossens</a>.
    <a href="index.html">Listen</a> ·
    <a href="https://github.com/mugoosse/listen">Source</a> ·
    <a href="https://github.com/mugoosse/listen/blob/main/LICENSE">AGPL 3.0</a> ·
    <a href="security.html">Security</a> ·
    <a href="privacy.html">Privacy</a> ·
    <a href="hipaa.html">HIPAA</a></p>
  </div>
</footer>

<script>
document.documentElement.className += ' js';
%(js)s
</script>

</body>
</html>
""" % {
        "title": channels.esc(audience["title"]),
        "desc": desc,
        "slug": audience["slug"],
        "eyebrow": channels.esc(audience["eyebrow"]),
        "h1": audience["h1"],
        "sub": channels.esc(audience["sub"]),
        "said": channels.esc(audience["said"]),
        "problem_head": channels.esc(audience["problem_head"]),
        "problem": channels.esc(audience["problem"]),
        "why_head": channels.esc(audience["why_head"]),
        "why": channels.esc(audience["why"]),
        "points": points,
        "obligation": audience["obligation"],
        "faq_head": channels.esc(audience["eyebrow"].replace("For ", "").capitalize()
                                 + " ask these."),
        "faq": faq_html,
        "faq_ld": faq_ld,
        "nav": nav,
        "css": channels.base_style() + channels.CHANNEL_CSS + AUDIENCE_CSS,
        "js": channels.shared_js(),
    }


def main():
    for audience in AUDIENCES:
        path = os.path.join(DOCS, audience["slug"] + ".html")
        io.open(path, "w", encoding="utf-8").write(render(audience, AUDIENCES))
        print("wrote docs/%s.html" % audience["slug"])
    print("\n%d audience pages" % len(AUDIENCES))


if __name__ == "__main__":
    main()
