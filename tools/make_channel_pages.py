#!/usr/bin/env python3
"""Build the per-channel landing pages under docs/.

One page per calling app somebody might search for, generated rather than
hand-written so nine of them cannot drift away from the design system on
index.html. Re-run after changing the CSS there.

    python3 tools/make_channel_pages.py

The pages are deliberately not near-duplicates. Each one argues from what is
actually different about that app, which is why CHANNELS carries a `spine`
rather than a template slot: a bot can be invited into a Zoom call and cannot be
invited into a WhatsApp one, and that changes the whole argument rather than one
noun in it.

Claims about the other app are kept to what is observable from outside it.
Listen's own behaviour is stated exactly; the other product's internals are not,
because they change without telling us.
"""

import io
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(HERE, "docs")

# --------------------------------------------------------------------------
# Brand glyphs, one path each on a 24x24 grid.
#
# From Simple Icons (simpleicons.org), whose SVG files are CC0. The marks
# themselves stay the trademarks of whoever owns them, and are used here the
# only way that is defensible: small, monochrome, in the page's own ink, to say
# truthfully that Listen records that app. Every page carries a line saying
# Listen is not affiliated with it.
#
# FaceTime is drawn rather than fetched, because Apple's product marks are not
# in that set.
# --------------------------------------------------------------------------

ICONS = {
    "whatsapp":
        "M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z",
    "telegram":
        "M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z",
    "signal":
        "M12 0q-.934 0-1.83.139l.17 1.111a11 11 0 0 1 3.32 0l.172-1.111A12 12 0 0 0 12 0M9.152.34A12 12 0 0 0 5.77 1.742l.584.961a10.8 10.8 0 0 1 3.066-1.27zm5.696 0-.268 1.094a10.8 10.8 0 0 1 3.066 1.27l.584-.962A12 12 0 0 0 14.848.34M12 2.25a9.75 9.75 0 0 0-8.539 14.459c.074.134.1.292.064.441l-1.013 4.338 4.338-1.013a.62.62 0 0 1 .441.064A9.7 9.7 0 0 0 12 21.75c5.385 0 9.75-4.365 9.75-9.75S17.385 2.25 12 2.25m-7.092.068a12 12 0 0 0-2.59 2.59l.909.664a11 11 0 0 1 2.345-2.345zm14.184 0-.664.909a11 11 0 0 1 2.345 2.345l.909-.664a12 12 0 0 0-2.59-2.59M1.742 5.77A12 12 0 0 0 .34 9.152l1.094.268a10.8 10.8 0 0 1 1.269-3.066zm20.516 0-.961.584a10.8 10.8 0 0 1 1.27 3.066l1.093-.268a12 12 0 0 0-1.402-3.383M.138 10.168A12 12 0 0 0 0 12q0 .934.139 1.83l1.111-.17A11 11 0 0 1 1.125 12q0-.848.125-1.66zm23.723.002-1.111.17q.125.812.125 1.66c0 .848-.042 1.12-.125 1.66l1.111.172a12.1 12.1 0 0 0 0-3.662M1.434 14.58l-1.094.268a12 12 0 0 0 .96 2.591l-.265 1.14 1.096.255.36-1.539-.188-.365a10.8 10.8 0 0 1-.87-2.35m21.133 0a10.8 10.8 0 0 1-1.27 3.067l.962.584a12 12 0 0 0 1.402-3.383zm-1.793 3.848a11 11 0 0 1-2.345 2.345l.664.909a12 12 0 0 0 2.59-2.59zm-19.959 1.1L.357 21.48a1.8 1.8 0 0 0 2.162 2.161l1.954-.455-.256-1.095-1.953.455a.675.675 0 0 1-.81-.81l.454-1.954zm16.832 1.769a10.8 10.8 0 0 1-3.066 1.27l.268 1.093a12 12 0 0 0 3.382-1.402zm-10.94.213-1.54.36.256 1.095 1.139-.266c.814.415 1.683.74 2.591.961l.268-1.094a10.8 10.8 0 0 1-2.35-.869zm3.634 1.24-.172 1.111a12.1 12.1 0 0 0 3.662 0l-.17-1.111q-.812.125-1.66.125a11 11 0 0 1-1.66-.125",
    "facetime":
        "M17 10.5V7a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-3.5l4 3.5V7l-4 3.5z",
    "zoom":
        "M5.033 14.649H.743a.74.74 0 0 1-.686-.458.74.74 0 0 1 .16-.808L3.19 10.41H1.06A1.06 1.06 0 0 1 0 9.35h3.957c.301 0 .57.18.686.458a.74.74 0 0 1-.161.808L1.51 13.59h2.464c.585 0 1.06.475 1.06 1.06zM24 11.338c0-1.14-.927-2.066-2.066-2.066-.61 0-1.158.265-1.537.686a2.061 2.061 0 0 0-1.536-.686c-1.14 0-2.066.926-2.066 2.066v3.311a1.06 1.06 0 0 0 1.06-1.06v-2.251a1.004 1.004 0 0 1 2.013 0v2.251c0 .586.474 1.06 1.06 1.06v-3.311a1.004 1.004 0 0 1 2.012 0v2.251c0 .586.475 1.06 1.06 1.06zM16.265 12a2.728 2.728 0 1 1-5.457 0 2.728 2.728 0 0 1 5.457 0zm-1.06 0a1.669 1.669 0 1 0-3.338 0 1.669 1.669 0 0 0 3.338 0zm-4.82 0a2.728 2.728 0 1 1-5.458 0 2.728 2.728 0 0 1 5.457 0zm-1.06 0a1.669 1.669 0 1 0-3.338 0 1.669 1.669 0 0 0 3.338 0z",
    "google-meet":
        "M5.53 2.13 0 7.75h5.53zm.398 0v5.62h7.608v3.65l5.47-4.45c-.014-1.22.031-2.25-.025-3.46-.148-1.09-1.287-1.47-2.236-1.36zM23.1 4.32c-.802.295-1.358.995-2.047 1.49-2.506 2.05-4.982 4.12-7.468 6.19 3.025 2.59 6.04 5.18 9.065 7.76 1.218.671 1.428-.814 1.328-1.64v-13a.828.828 0 0 0-.877-.825zM.038 8.15v7.7h5.53v-7.7zm13.577 8.1H6.008v5.62c3.864-.006 7.737.011 11.58-.009 1.02-.07 1.618-1.12 1.468-2.07v-2.51l-5.47-4.68v3.65zm-13.577 0c.02 1.44-.041 2.88.033 4.31.162.948 1.158 1.43 2.047 1.31h3.464v-5.62z",
    "microsoft-teams":
        "M20.625 8.127q-.55 0-1.025-.205-.475-.205-.832-.563-.358-.357-.563-.832Q18 6.053 18 5.502q0-.54.205-1.02t.563-.837q.357-.358.832-.563.474-.205 1.025-.205.54 0 1.02.205t.837.563q.358.357.563.837.205.48.205 1.02 0 .55-.205 1.025-.205.475-.563.832-.357.358-.837.563-.48.205-1.02.205zm0-3.75q-.469 0-.797.328-.328.328-.328.797 0 .469.328.797.328.328.797.328.469 0 .797-.328.328-.328.328-.797 0-.469-.328-.797-.328-.328-.797-.328zM24 10.002v5.578q0 .774-.293 1.46-.293.685-.803 1.194-.51.51-1.195.803-.686.293-1.459.293-.445 0-.908-.105-.463-.106-.85-.329-.293.95-.855 1.729-.563.78-1.319 1.336-.756.557-1.67.861-.914.305-1.898.305-1.148 0-2.162-.398-1.014-.399-1.805-1.102-.79-.703-1.312-1.664t-.674-2.086h-5.8q-.411 0-.704-.293T0 16.881V6.873q0-.41.293-.703t.703-.293h8.59q-.34-.715-.34-1.5 0-.727.275-1.365.276-.639.75-1.114.475-.474 1.114-.75.638-.275 1.365-.275t1.365.275q.639.276 1.114.75.474.475.75 1.114.275.638.275 1.365t-.275 1.365q-.276.639-.75 1.113-.475.475-1.114.75-.638.276-1.365.276-.188 0-.375-.024-.188-.023-.375-.058v1.078h10.875q.469 0 .797.328.328.328.328.797zM12.75 2.373q-.41 0-.78.158-.368.158-.638.434-.27.275-.428.639-.158.363-.158.773 0 .41.158.78.159.368.428.638.27.27.639.428.369.158.779.158.41 0 .773-.158.364-.159.64-.428.274-.27.433-.639.158-.369.158-.779 0-.41-.158-.773-.159-.364-.434-.64-.275-.275-.639-.433-.363-.158-.773-.158zM6.937 9.814h2.25V7.94H2.814v1.875h2.25v6h1.875zm10.313 7.313v-6.75H12v6.504q0 .41-.293.703t-.703.293H8.309q.152.809.556 1.5.405.691.985 1.19.58.497 1.318.779.738.281 1.582.281.926 0 1.746-.352.82-.351 1.436-.966.615-.616.966-1.43.352-.815.352-1.752zm5.25-1.547v-5.203h-3.75v6.855q.305.305.691.452.387.146.809.146.469 0 .879-.176.41-.175.715-.48.304-.305.48-.715t.176-.879Z",
    "slack-huddles":
        "M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z",
    "discord":
        "M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z",
}


def icon(slug):
    """The glyph for a channel, sized to sit on a line of text."""
    path = ICONS.get(slug)
    if not path:
        return ""
    return ('<svg class="chan-icon" viewBox="0 0 24 24" aria-hidden="true" '
            'focusable="false"><path d="%s"/></svg>' % path)


# --------------------------------------------------------------------------
# The three arguments. Which one a channel gets is the whole reason its page
# is not the same page with a name swapped in.
# --------------------------------------------------------------------------

SPINES = {
    # Nothing can be invited into the call, so tapping the Mac's own audio is
    # not a preference, it is the only thing that can work.
    "no-bot": {
        "heading": "Just the two of you.",
        "body": (
            "Meeting notetakers work by being invited into a call as a "
            "participant. A {name} call has no invitation to send, which is why "
            "most notetakers simply do not cover it. Listen never needed one: it "
            "records what your Mac is already playing, so the call is an "
            "ordinary sound on your machine and nothing has to let it in."
        ),
        "points": [
            "Works whether you use the {name} app or {name} in a browser tab",
            "{name} needs nothing installed, configured or connected",
            "Your call stays end to end encrypted; Listen records your own end of it",
        ],
    },
    # A bot exists and will show up in the participant list with a name on it.
    "quiet": {
        "heading": "Only the people you invited.",
        "body": (
            "The usual way to take notes in a {name} call is to let a bot join "
            "it, where it sits in the participant list with a name on it for the "
            "whole meeting. Listen records the audio your Mac is already playing "
            "instead, so the call has exactly the people in it that you invited."
        ),
        "points": [
            "Nothing is added to the participant list",
            "No calendar access and no account connected to {name}",
            "Works on a call somebody else scheduled, and on one nobody scheduled",
        ],
    },
    # Ad hoc, unscheduled, so calendar-driven tools never see it at all.
    "adhoc": {
        "heading": "The five minute call, kept.",
        "body": (
            "A {name} call tends to start because somebody had a question, not "
            "because it was in a calendar a week ago. Notetakers that work from "
            "your calendar never see those, so the conversations that actually "
            "decide things are the ones that go unrecorded. Listen starts from "
            "the menu bar, in the second you need it."
        ),
        "points": [
            "No calendar entry needed, because nothing is looked up",
            "Press record once the call is already going and keep the rest",
            "Works the same whether two people are on it or ten",
        ],
    },
}

# --------------------------------------------------------------------------
# The channels.
# --------------------------------------------------------------------------

CHANNELS = [
    {
        "slug": "whatsapp",
        "name": "WhatsApp",
        "spine": "no-bot",
        "blurb": "the calls a business actually runs on in most of the world",
        "sub": (
            "Listen records WhatsApp calls straight from your Mac, writes them "
            "down and works out who said what. Nothing joins the call, and the "
            "recording never leaves your computer."
        ),
        "why": (
            "In a great many places WhatsApp is not the casual option, it is the "
            "business line: the number a client has, the thread a deal lives in, "
            "the call that decides something. Almost every meeting notetaker was "
            "built for a calendar full of Zoom links instead, so the people doing "
            "business this way have been left to write it down by hand."
        ),
        "faq": [
            ("Can you record a WhatsApp call on a Mac?",
             "Yes. Listen records the audio your Mac is playing along with your "
             "microphone, so a WhatsApp call is captured the same way any other "
             "sound on the machine is. It works with the WhatsApp desktop app "
             "and with WhatsApp Web in a browser."),
            ("Does WhatsApp tell the other person I am recording?",
             "No. Listen runs on your Mac and has no connection to WhatsApp, so "
             "WhatsApp has nothing to report. That puts telling them squarely on "
             "you, and in many places the law agrees. Say you are recording."),
            ("Does it record both sides of the call?",
             "Yes, and it keeps them apart. Your microphone goes to one track and "
             "everything WhatsApp plays goes to another, which is also what lets "
             "Listen tell who was speaking when it writes the call up."),
            ("Does WhatsApp video work as well as voice?",
             "Yes. Listen takes the audio either way. The video is not recorded."),
            ("Do I need to install anything inside WhatsApp?",
             "No. There is no plugin, no bot, no linked account and no permission "
             "to grant inside WhatsApp. Listen asks macOS for permission to record "
             "audio, and that is the whole setup."),
            ("Can I record a WhatsApp call on my iPhone?",
             "Not from the phone. Listen for Mac records calls that happen on the "
             "Mac. If you take WhatsApp calls on your computer, that is the one "
             "you want."),
            ("What about voice messages somebody sent me?",
             "Save the file and run it through Listen and you get a transcript "
             "back. That path needs no permissions at all."),
        ],
    },
    {
        "slug": "telegram",
        "name": "Telegram",
        "spine": "no-bot",
        "blurb": "the calls that happen inside a chat, not on a calendar",
        "sub": (
            "Listen records Telegram calls from your Mac, writes them down and "
            "works out who said what. Nothing joins the call, and nothing is "
            "uploaded anywhere."
        ),
        "why": (
            "Telegram calls start from a conversation rather than from an invite, "
            "which is exactly the sort of call a notetaker built around a calendar "
            "will never notice. If the decision got made on Telegram, the record "
            "of it has been living in your memory."
        ),
        "faq": [
            ("Can you record a Telegram call on a Mac?",
             "Yes. Listen records what your Mac plays along with your microphone, "
             "so a Telegram call is captured like any other audio on the machine. "
             "The desktop app and the browser both work."),
            ("Does Telegram notify the other person?",
             "No. Listen has no connection to Telegram and Telegram has no way to "
             "know. Which makes telling them your job, and often the law's "
             "requirement. Say you are recording."),
            ("Does it separate the two voices?",
             "Yes. Your microphone and the call audio are recorded as separate "
             "tracks, so the transcript can attribute the turns rather than "
             "running them together."),
            ("Do I need a bot or an API key?",
             "No. Nothing is installed in Telegram and no account is connected."),
            ("Does it work on group calls?",
             "Yes. Everyone on the far side arrives on one track, and Listen "
             "separates the voices on it and lets you name them once each."),
        ],
    },
    {
        "slug": "signal",
        "name": "Signal",
        "spine": "no-bot",
        "blurb": "a private call, written up just as privately",
        "sub": (
            "Listen records Signal calls from your Mac and transcribes them on "
            "the same machine. Nothing joins the call and nothing is uploaded, "
            "which is the only way a Signal call should ever be written down."
        ),
        "why": (
            "Anybody choosing Signal has already decided who they are willing to "
            "trust with a conversation. Sending that same call to a transcription "
            "service would undo the decision entirely. Listen is the only shape "
            "that fits: the recording, the transcript and the speaker names are "
            "all made on your own Mac, and there is no server anywhere holding "
            "any of it."
        ),
        "faq": [
            ("Can you record a Signal call on a Mac?",
             "Yes. Listen records your microphone and the audio your Mac is "
             "playing, so a Signal Desktop call is captured like any other sound "
             "on the machine."),
            ("Does the recording get uploaded for transcription?",
             "No. Transcription runs on your Mac's own chip. The audio and the "
             "transcript stay in a folder on your disk, and Listen has no server "
             "to send them to."),
            ("Does this weaken Signal's encryption?",
             "It does not touch it. The call is still end to end encrypted in "
             "transit. Listen records your end of it after it has been decrypted "
             "for you to hear, which is the same thing your speakers do."),
            ("Does Signal notify the other person?",
             "No, and that is the reason to tell them yourself. A Signal user in "
             "particular has chosen the app for a reason, so recording without "
             "saying so is a poor way to treat them."),
            ("Is Listen itself auditable?",
             "It is open source under the AGPL, so the claim on this page can be "
             "checked against the code rather than taken on faith."),
        ],
    },
    {
        "slug": "facetime",
        "name": "FaceTime",
        "spine": "no-bot",
        "blurb": "the call your Mac was already built for",
        "sub": (
            "Listen records FaceTime calls on your Mac, writes them down and "
            "works out who spoke. No bot, no account, and nothing leaves the "
            "machine."
        ),
        "why": (
            "FaceTime has no notetaker ecosystem at all, because there is nothing "
            "for a notetaker to join. That leaves anybody doing real work over "
            "FaceTime with a screen recording at best. Listen treats it as what it "
            "is: audio your Mac is playing, and therefore audio it can write down."
        ),
        "faq": [
            ("Can you record a FaceTime call with audio on a Mac?",
             "Yes. Listen records your microphone and everything your Mac plays, "
             "which includes the other side of a FaceTime call. macOS screen "
             "recording is not involved and is not needed."),
            ("Does it record FaceTime video?",
             "No. Listen is about what was said, so it keeps the audio and the "
             "transcript rather than a video file the size of the meeting."),
            ("Does the other person get told?",
             "FaceTime has nothing to tell them, because Listen is not part of "
             "the call. Tell them yourself."),
            ("Does it work with a FaceTime group call?",
             "Yes. Everyone else arrives on one track and Listen separates the "
             "voices on it, so the transcript still says who said what."),
            ("Does it work on iPhone FaceTime calls?",
             "Not from the phone. This records calls that happen on your Mac."),
        ],
    },
    {
        "slug": "zoom",
        "name": "Zoom",
        "spine": "quiet",
        "blurb": "a meeting recorded without a stranger in the participant list",
        "sub": (
            "Listen records Zoom meetings from your Mac and writes them up "
            "locally. No bot joins, nobody is notified, and the recording stays "
            "on your computer."
        ),
        "why": (
            "Zoom is well served by notetakers, and every one of them announces "
            "itself in the participant list. That is fine for an internal "
            "stand-up and quite wrong for a first call with a client, an "
            "interview, or a conversation somebody agreed to have with you and "
            "not with a vendor."
        ),
        "faq": [
            ("Can Listen record a Zoom meeting without a bot?",
             "Yes. It records your microphone and the audio Zoom is playing, so "
             "nothing is added to the meeting and the participant list is exactly "
             "who you invited."),
            ("Do I have to be the host?",
             "No. Listen records your own machine, so it does not care who owns "
             "the meeting or whether recording is permitted in Zoom's settings."),
            ("Does Zoom tell people I am recording?",
             "Zoom announces its own recording feature. It has no way to know "
             "about this one, which is why you should say so yourself."),
            ("Does it need my calendar?",
             "No. The calendar is optional and only used to name recordings after "
             "the meeting they line up with. Refusing it costs nothing else."),
            ("Does it work with Zoom in a browser?",
             "Yes. Listen records the audio, so it makes no difference whether "
             "that is the Zoom app or a browser tab."),
        ],
    },
    {
        "slug": "google-meet",
        "name": "Google Meet",
        "spine": "quiet",
        "blurb": "a browser tab is still just audio on your Mac",
        "sub": (
            "Listen records Google Meet calls from your Mac and transcribes them "
            "there. Nothing joins the call, and no Google account is connected to "
            "anything."
        ),
        "why": (
            "Google Meet runs in a browser tab, which most notetakers treat as a "
            "problem to be solved with an extension, a bot, or access to your "
            "Google account. Listen records the sound the tab is making. There is "
            "nothing to connect and nothing to grant."
        ),
        "faq": [
            ("Can you record a Google Meet call on a Mac?",
             "Yes. Listen records the audio your browser is playing along with "
             "your microphone, so a Meet call needs no extension and no bot."),
            ("Do I have to give it access to my Google account?",
             "No. Listen never connects to Google. If you want recordings named "
             "after the meeting they match, it reads the calendar macOS already "
             "has, which needs no sign-in of its own."),
            ("Does it work without being the organiser?",
             "Yes. Nothing about the meeting has to permit it, because nothing "
             "about the meeting is involved."),
            ("Does Meet notify people?",
             "Meet announces its own recording. It cannot see this one. Tell them "
             "yourself."),
            ("Does it capture people who join late?",
             "Yes. Everyone on the far side is on one track for the whole call, "
             "and Listen separates the voices on it however many there are."),
        ],
    },
    {
        "slug": "microsoft-teams",
        "name": "Microsoft Teams",
        "spine": "quiet",
        "blurb": "notes from a Teams call, without asking IT for anything",
        "sub": (
            "Listen records Microsoft Teams calls from your Mac and writes them "
            "up on the same machine. No bot in the meeting, no tenant admin, and "
            "nothing uploaded."
        ),
        "why": (
            "Getting a notetaker into Teams usually means an administrator "
            "approving an app for the whole organisation, which is a long "
            "conversation to have about your own notes. Listen records your Mac. "
            "There is nothing for anybody to approve, and if your organisation "
            "would rather lock it down, it can be managed with the device profiles "
            "IT already uses."
        ),
        "faq": [
            ("Can you record a Teams meeting on a Mac without admin approval?",
             "Listen records your own microphone and your Mac's own audio, so it "
             "is not an app inside Teams and nothing is installed in your tenant. "
             "Whether you may record a given meeting is a question for your "
             "employer, not for the software."),
            ("Does it appear in the meeting?",
             "No. Nothing is added to the participant list."),
            ("Can my organisation control it?",
             "Yes. Listen reads standard managed preferences, so an IT team can "
             "force sync off, restrict questions to a model on the machine, turn "
             "off dictation history or redirect backups."),
            ("Does it need a Microsoft account?",
             "No account of any kind is involved."),
            ("Does it work with Teams in a browser?",
             "Yes, the same as the desktop app."),
        ],
    },
    {
        "slug": "slack-huddles",
        "name": "Slack huddles",
        "spine": "adhoc",
        "blurb": "the five minute call that decided the thing",
        "sub": (
            "Listen records Slack huddles from your Mac and writes them down "
            "locally. Nothing joins, nothing is scheduled, and nothing is "
            "uploaded."
        ),
        "why": (
            "A huddle is the least ceremonious call there is and often the most "
            "consequential: two people, no invite, five minutes, a decision. "
            "Nothing that works from your calendar will ever see one. Listen "
            "starts from the menu bar while the huddle is still going."
        ),
        "faq": [
            ("Can you record a Slack huddle on a Mac?",
             "Yes. Listen records your microphone and the audio Slack is playing, "
             "so a huddle is captured like any other call on the machine."),
            ("Can I start recording after the huddle has begun?",
             "Yes, and you will get everything from the moment you press it. "
             "Recording starts on the press rather than on a confirmation, so you "
             "do not lose the first minute deciding."),
            ("Does it show in the huddle?",
             "No. Nothing joins and nobody is added."),
            ("Does it work for a huddle with several people?",
             "Yes. Everyone else is on one track and Listen separates the voices "
             "on it."),
            ("Does it record the screen share?",
             "No, only the audio and what was said over it."),
        ],
    },
    {
        "slug": "discord",
        "name": "Discord",
        "spine": "adhoc",
        "blurb": "a voice channel, written down without a bot in it",
        "sub": (
            "Listen records Discord calls from your Mac and transcribes them "
            "there. No recording bot in the channel, and nothing uploaded to "
            "anybody."
        ),
        "why": (
            "The usual way to record a Discord call is to invite a bot into the "
            "voice channel, which everybody can see, which needs permissions on "
            "the server, and which sends the audio somewhere else. Listen records "
            "your own machine instead, so it works on a server you do not "
            "administer and on a direct call with one person."
        ),
        "faq": [
            ("Can you record a Discord call without a bot?",
             "Yes. Listen records your microphone and the audio Discord is "
             "playing, so nothing is added to the voice channel and no server "
             "permissions are needed."),
            ("Does it work in a direct call, not just a server?",
             "Yes. It makes no difference to Listen where the call is happening."),
            ("Does everyone end up as one speaker?",
             "No. Everyone on the far side shares a track, and Listen separates "
             "the voices on it, so you can name each of them once."),
            ("Do I need to be a server admin?",
             "No. Nothing is installed on the server."),
            ("Does it record the stream or the screen share?",
             "No. Listen keeps the audio and the transcript."),
        ],
    },
]

# --------------------------------------------------------------------------
# Rendering.
# --------------------------------------------------------------------------

def esc(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def base_style():
    """The design system, lifted from index.html so it cannot drift."""
    index = io.open(os.path.join(DOCS, "index.html"), encoding="utf-8").read()
    css = index[index.index("<style>") + len("<style>"):index.index("</style>")]
    # The switcher only exists on the home page.
    css = re.sub(r"/\* ---------- the feature switcher.*?/\* ---------- misc",
                 "/* ---------- misc", css, flags=re.S)
    css = re.sub(r"@media \(max-width: 860px\) \{.*?\n\}\n", "", css, flags=re.S)
    return css


def shared_style():
    return base_style() + CHANNEL_CSS


CHANNEL_CSS = """
/* ---------- channel pages ---------------------------------------------- */

.steps { counter-reset: step; margin: 34px 0 30px; padding: 0; list-style: none; }
.steps li {
  counter-increment: step;
  position: relative; padding: 0 0 0 46px; margin: 0 0 26px;
  font-size: 16.5px; color: var(--ink-soft);
}
.steps li:last-child { margin-bottom: 0; }
.steps li::after {
  content: ""; position: absolute; left: 15px; top: 34px; bottom: -22px;
  width: 1px; background: var(--rule);
}
.steps li:last-child::after { display: none; }
.steps li::before {
  content: counter(step);
  position: absolute; left: 0; top: -2px;
  width: 30px; height: 30px; border-radius: 50%;
  background: var(--paper-warm); border: 1px solid var(--rule);
  display: grid; place-items: center;
  font-size: 14px; font-family: var(--serif); color: var(--ink);
}
.steps b { color: var(--ink); font-weight: 600; }

.faq { margin: 30px 0 0; }
.faq details {
  border-top: 1px solid var(--rule);
  padding: 0;
}
.faq details:last-of-type { border-bottom: 1px solid var(--rule); }
.faq summary {
  cursor: pointer; list-style: none;
  padding: 18px 30px 18px 0; position: relative;
  font-family: var(--serif); font-size: 19px; line-height: 1.3;
  color: var(--ink);
}
.faq summary::-webkit-details-marker { display: none; }
.faq summary::after {
  content: "+"; position: absolute; right: 4px; top: 17px;
  font-family: var(--sans); font-size: 19px; color: var(--ink-faint);
}
.faq details[open] summary::after { content: "\\2212"; }
.faq summary:focus-visible { outline: 2px solid var(--blue); outline-offset: -2px; }
.faq .answer { padding: 0 30px 20px 0; }
.faq .answer p { font-size: 16px; margin: 0; }

/* .channel-nav itself comes from index.html with the rest of the design
   system. Only the current-page state is needed here, because the home page
   has no current channel. */
.channel-nav a[aria-current="page"] {
  background: var(--paper-warm); border-color: var(--ink-faint); color: var(--ink);
}
.channel-nav a[aria-current="page"] .chan-icon { opacity: 1; }

.consent {
  border-left: 2px solid var(--blue); background: var(--paper-warm);
  border-radius: 0 12px 12px 0; padding: 20px 24px; margin: 34px 0 0;
}
.consent p { font-size: 15.5px; margin: 0; }
.consent strong { color: var(--ink); }

.legal { font-size: 13.5px; color: var(--ink-faint); margin: 30px 0 0; }

/* The hero sub is the last child of its column here, so `p:last-child` takes
   its bottom margin away and the buttons end up against it. */
header.hero .buttons { margin-top: 34px; }

/* The home page's hero frame holds a screenshot, so running it the full width
   of the page is right. This one is empty until record.mp4 exists, and 16:10
   across the full width is 640 points of nothing, 364 wider than the copy it
   belongs to. Held nearer the text measure it stays a picture rather than a
   void, and the clip that eventually lands in it is still comfortably bigger
   than the ones in the switcher on the home page. */
header.hero figure.demo { max-width: 820px; }
"""


def render(channel, others):
    name = channel["name"]
    spine = SPINES[channel["spine"]]

    def fill(text):
        return text.replace("{name}", name)

    faq_html = []
    for q, a in channel["faq"]:
        faq_html.append(
            '        <details>\n'
            '          <summary>%s</summary>\n'
            '          <div class="answer"><p>%s</p></div>\n'
            '        </details>' % (esc(q), esc(a)))

    # A FAQPage block, so the answers can be read by a search engine and by the
    # assistants people increasingly ask instead of one.
    import json
    faq_ld = json.dumps({
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {"@type": "Question", "name": q,
             "acceptedAnswer": {"@type": "Answer", "text": a}}
            for q, a in channel["faq"]
        ],
    }, indent=2)

    nav = []
    for other in others:
        current = ' aria-current="page"' if other["slug"] == channel["slug"] else ""
        nav.append('      <a href="%s.html"%s>%s<span>%s</span></a>' %
                   (other["slug"], current, icon(other["slug"]), esc(other["name"])))

    points = "\n".join(
        "              <li>%s</li>" % esc(fill(p)) for p in spine["points"])

    title = "Record %s calls on your Mac | Listen" % name
    desc = ("Record %s calls on a Mac and get a transcript with names on it. "
            "No bot joins the call, no account, and nothing is uploaded."
            % name)

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
      <p class="eyebrow">Works with %(name)s</p>
      <h1>Record a %(name)s call<br>on your Mac.</h1>
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

    <figure class="demo">
      <div class="frame empty" data-shot="record" data-seconds="14"
           data-note="menu bar → Start → meters → Stop → Keep"></div>
      <figcaption>Starting and keeping a recording, entirely from the menu bar.</figcaption>
    </figure>
  </div>
</header>

<section id="how">
  <div class="page">
    <div class="col">
      <p class="eyebrow">How it works</p>
      <h2>Already recording when it asks.</h2>
      <ol class="steps">
        <li><b>Take the call.</b> Listen notices by itself. An app that is
        listening and speaking at the same moment is on a call, and nothing else
        on a Mac routinely does both, so there is no list of supported apps to be
        left off.</li>
        <li><b>Answer the question.</b> A small panel asks whether you are in a
        meeting, and it has <b>already started recording</b>, so the answer costs
        you nothing either way. Say yes and it carries on. Say no and the
        recording is thrown away. Say never and it stops asking about %(name)s.</li>
        <li><b>Hang up.</b> A recording it started stops when the call does, and
        the transcript is written on your own Mac, usually before you have
        finished closing the window.</li>
      </ol>
      <p>The menu bar is still there for a call it did not catch, or one you want
      running before anybody has joined. Either way your microphone goes to one
      track and everything %(name)s plays goes to another, which is what lets
      Listen tell the voices apart afterwards.</p>
    </div>
  </div>
</section>

<section id="different">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Why this one is different</p>
      <h2>%(spine_heading)s</h2>
      <p class="lead">%(spine_body)s</p>
      <ul class="points">
%(points)s
      </ul>
      <p>%(why)s</p>
    </div>
  </div>
</section>

<section id="after">
  <div class="page">
    <div class="col">
      <p class="eyebrow">After the call</p>
      <h2>Never listen to it twice.</h2>
      <p class="lead">Give the call your attention, not your notepad. Listen
      writes it up on your Mac's own chip, works out who spoke, and remembers the
      voices, so the regulars name themselves after the first time.</p>
      <ul class="points">
        <li>Search every call you have ever had, instantly and offline</li>
        <li>Ask a question across all of them and click through to the answer</li>
        <li>Write your own notes during the call, when they are worth the most</li>
        <li>Fix a name or a sentence without re-transcribing anything</li>
      </ul>
      <p><a href="index.html">See everything Listen does →</a></p>
    </div>
  </div>
</section>

<section id="privacy">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Privacy</p>
      <h2>Your calls stay yours.</h2>
      <p class="lead">There is no Listen server, because there are no servers.
      The recording, the transcript and the names on it are all made on your own
      computer. No account, and nothing reports back beyond anonymous usage
      statistics, on by default and turned off in Settings whenever you like.</p>
      <p>Listen is open source under the AGPL, so none of that has to be taken on
      trust. <a href="security.html">What runs where</a> sets out every
      connection it can make and how to check each one yourself, and there are
      answers ready for a <a href="privacy.html">privacy</a> or
      <a href="hipaa.html">HIPAA</a> review.</p>

      <div class="consent">
        <p><strong>Tell the other person.</strong> %(name)s has no way to know
        that Listen is running, so saying so is on you. In many places it is also
        the law, and it varies by country and by state. If the call is with a
        client or a patient, get their agreement on the recording before you
        start.</p>
      </div>
    </div>
  </div>
</section>

<section id="faq">
  <div class="page">
    <div class="col">
      <p class="eyebrow">Questions</p>
      <h2>Recording %(name)s on a Mac.</h2>
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
      <h2>Try it on your next call.</h2>
      <p class="lead">Free to download, and open source. Apple silicon, macOS
      14 or later. The speech model is about 2.5 GB and downloads once, the first
      time you run it.</p>
      <div class="buttons">
        <a class="button primary" href="https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg" data-rybbit-event="mac_download_clicked" data-rybbit-prop-slot="footer">Download for macOS</a>
        <a class="button" href="https://github.com/mugoosse/listen">Read the source</a>
      </div>

      <p class="eyebrow" style="margin-top:44px">Also works with</p>
      <div class="channel-nav">
%(nav)s
      </div>

      <p class="legal">Listen is not affiliated with, endorsed by or connected to
      %(name)s or its owner. %(name)s is named here only to describe what Listen
      records.</p>
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
        "title": esc(title),
        "desc": esc(desc),
        "slug": channel["slug"],
        "name": esc(name),
        "sub": esc(channel["sub"]),
        "why": esc(channel["why"]),
        "spine_heading": esc(fill(spine["heading"])),
        "spine_body": esc(fill(spine["body"])),
        "points": points,
        "faq": "\n".join(faq_html),
        "faq_ld": faq_ld,
        "nav": "\n".join(nav),
        "css": shared_style(),
        "js": shared_js(),
    }


def shared_js():
    """The media and Intel-check code from index.html, minus the switcher."""
    index = io.open(os.path.join(DOCS, "index.html"), encoding="utf-8").read()
    js = index[index.index("<script>") + len("<script>"):index.rindex("</script>")]
    start = js.index("// ---------------------------------------------------------------------------\n// Media")
    switch = js.index("// ---------------------------------------------------------------------------\n// The feature switcher")
    intel = js.index("// ---------------------------------------------------------------------------\n// Tell an Intel visitor")
    media = js[start:switch]
    hydrate = ("\n// Every frame on this page is outside a switcher, so all of them load now.\n"
               "Array.prototype.forEach.call(\n"
               "  document.querySelectorAll('.frame[data-shot]'), Media.hydrate);\n\n")
    return media + hydrate + js[intel:]


def main():
    if not os.path.isdir(DOCS):
        sys.exit("no docs/ directory next to tools/")
    for channel in CHANNELS:
        path = os.path.join(DOCS, channel["slug"] + ".html")
        io.open(path, "w", encoding="utf-8").write(render(channel, CHANNELS))
        print("wrote docs/%s.html  (%s)" % (channel["slug"], channel["name"]))
    print("\n%d channel pages" % len(CHANNELS))


if __name__ == "__main__":
    main()
