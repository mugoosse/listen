# Listen

**Listen is a private second brain for your conversations.** It records calls
and rooms on your Mac and iPhone, works out who said what, and builds a memory
of the people, projects and decisions in them that an AI assistant can actually
use. Transcription runs on your own machine.

## → [listenbrain.app](https://listenbrain.app)

Everything is there: what it does, the documentation, the release notes, the
privacy policy and the full dictionary of what the optional telemetry sends.

| | |
|---|---|
| **Download for macOS** | [dl.listenbrain.app/Listen.dmg](https://dl.listenbrain.app/Listen.dmg) |
| **Homebrew** | `brew install --cask mugoosse/tap/listen` |
| **iPhone** | [TestFlight](https://testflight.apple.com/join/GEFrDyzh) |
| **Documentation** | [listenbrain.app/docs](https://listenbrain.app/docs) |
| **Release notes** | [listenbrain.app/changelog](https://listenbrain.app/changelog) |
| **Something wrong** | [listenbrain.app/support](https://listenbrain.app/support) |

## Why this repository has no source in it

Listen was developed in the open under AGPL-3.0 up to version 0.46.0. It is now
closed source, and the code lives in a private repository.

This repository stays public and keeps its name on purpose, because two things
in released copies of Listen point at it and cannot be edited afterwards:

- **The update feed.** Every build before 0.46.0 reads
  `releases/latest/download/appcast.xml` from here and can read nothing else,
  ever. The release below is that feed, frozen. A copy older than 0.46.0 finds
  it, updates once, and from then on reads the feed at
  [dl.listenbrain.app](https://dl.listenbrain.app/appcast.xml) like every
  current build.
- **Help → Listen Website**, which pointed at `mugoosse.github.io/listen` in
  builds up to 0.44.0. That page is still served from `docs/` here and still
  redirects to listenbrain.app.

So this is not an empty shell for its own sake. Deleting it, or making it
private, would silently strand people who installed Listen while it was open
and never tell them why their app stopped updating.

Nothing here is the product. Go to [listenbrain.app](https://listenbrain.app).
