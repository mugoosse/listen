# Product Marketing Context

*Working draft v1 — 9 September 2026*

This document records the current positioning direction for Listen. Product
capabilities are grounded in the running Mac and iPhone apps. Audience,
category, pricing and conversion choices remain hypotheses until customer
language and willingness to pay validate them.

## Product Overview

**One-liner:** Listen is a private, conversation-first second brain that
remembers the people, projects, decisions and details in your real
conversations — and gives that context back to you and the AI tools you use.

**What it does:** Listen records calls on the Mac and conversations or memos on
the iPhone. It writes them down, works out who said what, remembers voices, and
builds a source-backed memory of people and projects over time. You can search
or ask across that memory, check every answer against the original words, and
let tools such as Claude Code or Codex retrieve the context through MCP.

**Product category:**

- Primary category direction: private personal second brain
- More precise wedge: conversation-first second brain
- Familiar entry category: AI meeting notes / meeting memory
- Adjacent categories: personal knowledge management, AI memory, relationship
  intelligence and voice productivity

The site should use the familiar meeting-notes job to make the product legible,
but it should not frame Listen as merely a meeting recorder or transcription
utility.

**Product type:** Native, local-first macOS app with an iPhone companion. The
current Mac app is free software; the memory can be read by the user's chosen AI
instead of requiring a proprietary Listen model or account.

**Brand and domain:** The product remains **Listen**. `listenbrain.app` is the
primary marketing domain and a category signal, not necessarily a new product
name. Avoid presenting the brand as “ListenBrain” unless that is chosen
explicitly later.

**Business model:** Not finalized. The Mac app is currently free and AGPL. An
earlier iPhone proposal suggested five free recordings followed by a $79
perpetual unlock, but this is not a validated or adopted cross-product pricing
model. Do not publish subscription, lifetime or bundle pricing until decided.

## Target Audience

**Best-fit customer hypothesis:** People whose work depends on remembering
conversations, relationships and decisions — especially self-purchasing Apple
users who already use AI and carry too much context in their heads.

**Initial audience candidates:**

- Independent consultants and fractional leaders
- Founders, product leaders and researchers conducting frequent customer calls
- Coaches and advisers with recurring, high-context client relationships
- Recruiters, journalists and other conversation-heavy independent
  professionals
- AI power users who repeatedly have to brief a new model or agent on context

These are discovery segments, not confirmed ICPs. The homepage should initially
address the shared situation rather than naming six professions: **“Your work
happens in conversations, and you cannot afford to lose the context.”**

**Decision-maker:** Usually the person using the product and buying it for
themselves. A future team product would introduce security, administration and
procurement stakeholders that the current product is not designed around.

**Primary use case:** Turn important conversations into a living, searchable
and verifiable personal memory that improves over time.

**Jobs to be done:**

- Stay present in a conversation without trying to capture every detail.
- Recall what was said, decided or promised weeks later.
- Remember the history, preferences and changing circumstances of the people
  and projects that matter.
- Give an AI assistant the relevant personal context without explaining
  everything again or surrendering the entire library.
- Verify a generated answer by opening the exact conversation behind it.

**Representative use cases:**

- “Catch me up before I speak to Alex again.”
- “What did we decide about pricing, and who disagreed?”
- “What has changed on the Atlas project since June?”
- “What does Maria care about, and where did I learn that?”
- “What did I promise to follow up on this week?”
- Ask Claude Code or Codex to draft work using context from relevant customer
  conversations instead of pasting transcripts into a prompt.

## Personas

| Persona | Situation | Cares about | Value we promise |
| --- | --- | --- | --- |
| Independent operator | Many client conversations; context lives in their head | Attention, follow-through, privacy | Remember every client without running a CRM or taking exhaustive notes |
| Founder or product leader | Customer calls, team decisions and product history are scattered | Better decisions and faster synthesis | Turn conversation history into usable context for research, planning and AI work |
| Relationship-heavy professional | Recurring conversations where personal details and history matter | Trust, continuity and discretion | Arrive remembering what matters and verify where every detail came from |
| AI power user | Repeats background in every new chat, model or agent | Portable context and better output | Give existing AI tools a personal memory instead of starting from zero |

## Problems & Pain Points

**Core problem:** The context that makes someone effective — decisions, nuance,
relationships, promises and the reasons behind them — is spoken and then
disappears. Human memory is incomplete, manual notes capture only what the
person had time to write, and generic AI knows none of it.

**Why existing alternatives fall short:**

- A transcript is an archive, not a useful memory.
- Meeting summaries flatten nuance and are difficult to verify later.
- Notes require the user to notice, write and organize the important parts.
- CRMs feel like data entry and reduce a relationship to fields.
- Platform AI memory is tied to one vendor and rarely contains the source
  conversations that explain why something is true.
- Cloud meeting bots introduce another participant, another account and another
  company holding sensitive material.
- General second-brain tools still need the user to feed and organize them.

**What it costs:** Repeated explanations, generic AI output, weak preparation,
missed follow-ups, decisions reopened because nobody remembers why, and the
small relationship details that quietly determine whether someone feels known.

**Emotional tension:**

- “I know we talked about this somewhere.”
- “I should remember this person better than I do.”
- “I cannot keep all of these projects and conversations in my head.”
- “My AI is powerful, but it does not know the things that make the answer
  useful to me.”

## Competitive Landscape

**Direct competitors:**

- Granola and other AI meeting assistants — strong meeting workflow and polished
  generated output; customers still primarily understand them through the
  meeting-notes category.
- Jamie, Plaud and similar capture products — reduce note-taking but generally
  compete on capture, summaries and hardware/cloud workflow.
- Apple Watch Recaps and platform-level ambient memory — may make casual recall
  effortless, but reported designs do not preserve a transcript or source that
  can be checked.

**Secondary competitors:**

- Notion, Obsidian, Reflect and other second-brain or PKM tools — useful stores
  of information, but the user usually has to capture and organize the material.
- nanoBrain and agent-memory systems — portable context for technical AI users,
  but require setup and capture primarily from digital work rather than the full
  conversation itself.
- ChatGPT, Claude and other vendor memory — convenient but vendor-bound and
  limited to what that vendor has been told.

**Indirect competitors:** Manual notes, calendar descriptions, searchable chat,
raw transcript folders, traditional CRMs and relying on human memory.

**Real competitive alternative:** Doing nothing and reconstructing the context
from memory, scattered notes and old messages when it becomes urgent.

## Differentiation

**Key differentiators:**

- Conversation-first: it captures the source where important context is
  naturally created.
- Source-backed: generated details and answers link back to what was actually
  said, by whom and when.
- Improves over time: selected people and projects can be kept current as new
  conversations arrive, while preserving earlier states and corrections.
- Correctable memory: the user can correct, pin, hide, exclude or delete
  generated details without changing the original recording.
- Private by architecture: transcription and retrieval can run locally; owner
  sync is encrypted on the device before reaching iCloud.
- AI-neutral: the user can query with a local model, their existing Claude Code
  or Codex subscription, or a configured compatible provider.
- Covers calls and rooms: separate Mac call capture and iPhone room/memo capture
  feed one library.

**How we do it differently:** Listen keeps the conversation as evidence, builds
a smaller useful memory above it, and retrieves only the context needed for the
question. The AI does not become the source of truth.

**Why that is better:** The user gets the speed of an AI summary without giving
up the ability to check, correct and own the underlying memory.

**Positioning statement:** For people whose work depends on conversations,
Listen is the private personal second brain that turns what was said into an
evolving memory of people, projects and decisions. Unlike a meeting summary or
vendor AI memory, every important detail can be checked against its source and
used by the AI tools the customer already trusts.

## Objections

| Objection | Response |
| --- | --- |
| “Isn't this just another meeting recorder?” | Recording is the input. The product is the memory that grows across conversations and becomes useful before the next one. |
| “Why not use Granola?” | If polished meeting notes are the whole job, Granola is a strong option. Listen is for people who want an owned, source-backed memory across calls, rooms, people, projects and their existing AI tools. |
| “An app remembering people sounds creepy.” | Recording is explicit, generated memory starts manually per person, automatic updates are optional, and details can be checked, corrected, hidden or deleted. |
| “Can I trust what the AI remembers?” | Every generated claim carries its source. Listen preserves uncertainty and changes over time rather than silently replacing history. |
| “I do not want another knowledge app to maintain.” | Listen starts from conversations the user is already having, recognizes people again and can update selected memories as new conversations arrive. |
| “Will my private conversations be uploaded?” | Core recording, transcription and search can stay on the user's devices. If the user chooses a hosted AI provider, Listen explains that boundary before sending selected text. |

**Anti-persona:** A company seeking a centralized, admin-controlled meeting
intelligence platform; someone who wants always-on covert ambient capture; a
Windows/Android-only user; or someone who only needs disposable summaries and
does not value retained source material.

## Switching Dynamics

**Push:** Important context is scattered or forgotten; meetings create more
admin; AI answers feel generic; the user repeatedly briefs tools from scratch.

**Pull:** A memory that builds itself from conversations, remembers people,
prepares useful context and makes existing AI meaningfully more personal.

**Habit:** Taking partial notes, searching Slack/email, keeping mental context,
copying transcripts into ChatGPT, and accepting that some details will be lost.

**Anxiety:** Recording consent, privacy, AI accuracy, setup effort, dependence on
a small product, and whether “second brain” means another system to maintain.

## Customer Language

**Language to validate in interviews:**

- “I know we talked about this somewhere.”
- “Catch me up before I talk to them again.”
- “What did we decide?”
- “I keep explaining the same context to AI.”
- “I want to be present instead of taking notes.”
- “I need to remember the person, not just the meeting.”

**Language supplied by the founder:**

- “A personal second brain that can give you superpowers when using AI.”
- “A self-learning, self-improving personal CRM,” as internal strategic
  shorthand, while avoiding “CRM” in customer-facing copy.
- “Speak in the language that our audience speaks.”

**Candidate customer proof requiring publication permission:**

> “I've tested many similar apps out there, and Listen is finally the one that
> stuck.” — Daniel Andrade

**Words and phrases to use:**

- remember people, projects and decisions
- what was actually said
- catch me up
- knows the context
- grows with every conversation
- linked to the source
- your conversations, your devices, your choice of AI
- stay present
- stop starting from zero

**Words and phrases to avoid in primary copy:**

- knowledge corpus
- context engine
- temporal provenance
- semantic embeddings
- vector database
- entity graph
- personal CRM
- revolutionary / game-changing / 10×
- “never forget anything” or other impossible absolutes

Technical terms such as MCP, local models and encrypted projections can appear
later on the page for readers who want implementation detail, after the human
value is understood.

**Glossary:**

| Term | Plain-language meaning |
| --- | --- |
| Second brain | A useful memory outside your head that you can search and ask |
| Source-backed | You can open the conversation that supports an answer |
| Personal memory | What Listen has learned from conversations the user chose to keep |
| People brief | A concise, editable view of what matters about a person and the history behind it |
| Project brief | Current decisions, context and changes connected to a project |
| Ask | Questions answered from the user's own Listen library |
| MCP | The connection that lets compatible AI tools retrieve Listen context; explain it as “use your Listen memory in your AI tools” before naming the protocol |

## Brand Voice

**Tone:** Warm, calm, intelligent and quietly confident.

**Style:** Plain spoken, specific and example-led. Prefer a recognizable moment
from the customer's day over a category abstraction. Use short sentences and
ordinary verbs: remember, ask, check, find, speak and know.

**Personality:** Thoughtful, capable, private, human and a little playful.

**Writing principles:**

- The customer is the protagonist; Listen is the memory that helps them.
- Lead with the life or work improvement. Explain the machinery afterwards.
- Show an example question and answer instead of claiming “powerful AI.”
- Privacy is a reason to trust the product, not the only reason to want it.
- Do not make fear, surveillance or competitor attacks the main emotional tone.
- Never hide a real limitation behind broad “AI” language.

## Proof Points

**Product proof available now:**

- Records microphone and Mac system audio separately without a meeting bot.
- Local transcription measured at about 240× real time on an M4 Max.
- Recognizes voices across meetings, with suggestions rather than silent
  automatic assignment.
- Answers across the library with numbered references to source material.
- Builds source-backed person/project briefs with correction and history.
- Local keyword and meaning-based search, including optional multilingual
  search.
- Encrypted owner-iCloud sync across Macs and iPhone.
- Works through the UI, command line and MCP.
- No Listen account or mandatory Listen-hosted AI service.

**Proof still needed for the new site:**

- Three to five approved customer quotes tied to a concrete use case.
- One end-to-end customer story: conversation → remembered context → better
  follow-up or AI output.
- A 20–30 second real-product hero demonstration centered on people/project
  memory, Ask, source verification and AI use rather than a transcript screen.
- Four or five short workflow loops and a small screenshot set that prove
  recognition, accumulated memory, citations, cross-device capture and user
  control with invented demo data.
- Customer language interviews and willingness-to-pay evidence.
- Clear, final pricing and packaging.

**Value themes:**

| Theme | Proof |
| --- | --- |
| Better memory | Cross-meeting people/project briefs, history and search |
| Better AI | Ask and MCP retrieve relevant personal context from the library |
| Trustworthy answers | Numbered sources, exact quotations and user corrections |
| Less maintenance | Conversations become the input; selected memories can update incrementally |
| Real ownership | Local processing, plain library files and encrypted owner sync |

## Goals

**Primary business goal:** Reposition Listen from a capable local meeting
recorder into an ownable, valuable personal-memory product and create a credible
path to paid adoption.

**Primary website conversion:** To be decided before implementation. Current
default is **Download Listen for Mac**; a commercial launch may instead require
**Join the early-access list** or **Start free**.

**Secondary conversions:** Watch the memory demo, understand the privacy model,
and install the iPhone companion.

**New domain:** `listenbrain.app`

**Current metrics:** Not recorded here. The site must define and measure hero
CTA clicks, successful downloads/sign-ups, activation of recording plus Ask or
memory, and return usage after the memory has had time to become valuable.

## Decisions Needed Before Public Launch

- Is “personal second brain” the public category or an internal positioning
  frame supported by a plainer hero?
- Is the first audience broad (“people whose work happens in conversations”) or
  narrow (for example consultants and fractional leaders)?
- Does the new commercial story include Speak/dictation or focus on Listen's
  conversation memory?
- What exactly is paid, and what remains the free/open-source edition?
- Is the primary CTA download, early access or purchase?
- Which two or three customer outcomes can be supported by approved evidence?
