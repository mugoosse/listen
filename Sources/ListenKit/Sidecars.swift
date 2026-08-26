import Foundation

/// `turns.json`: what the sidebar, the CLI and every screen in both apps read.
///
/// The unit the *reader* sees. `speakers.md` records that a sentence is edited
/// and a segment is what gets written, so nothing here writes back a turn: the
/// phone sends an edit and the Mac decides what that means on disk.
public struct Turn: Codable, Sendable, Equatable, Identifiable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String

    public var id: String { "\(start)-\(speaker)" }

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

/// `transcript.json`. Decoded loosely for the same reason `Metadata` is: this
/// file gained `cleanup`, `dictionary` and `wordLevel` over time and will gain
/// more, and a phone one version behind must not fail to show a transcript
/// because of a key it has never seen.
public struct StoredTranscript: Codable, Sendable {
    public var segments: [Turn]
    public var duration: Double?
    public var model: String?

    public init(segments: [Turn], duration: Double? = nil, model: String? = nil) {
        self.segments = segments; self.duration = duration; self.model = model
    }
}

/// `waveform.json`, precomputed by the Mac so neither device decodes audio to
/// draw a picture. The phone usually has the picture and not the audio.
public struct Waveform: Codable, Sendable {
    public var peaks: [Double]
    public var duration: Double?
    public var version: Int?
}

/// A note artifact. Markdown with YAML frontmatter, because `notes-tags-dictionary.md`
/// requires that a note file survive being written by hand.
///
/// `updated` is the compare-and-swap token. It is the only field either side
/// may not invent: the Mac rejects a write whose `updated` has moved, and the
/// phone then shows both versions rather than choosing one. A note is the only
/// thing in this system two people can edit at once, so it is the only thing
/// that needs the ceremony.
public struct Note: Codable, Sendable, Identifiable {
    public var slug: String
    public var title: String
    public var created: String
    public var updated: String
    public var source: String
    /// What was asked, in the words somebody actually used, when the note came
    /// out of a conversation. Listen 0.11.0 and later write it.
    public var prompt: String?
    /// The conversation this note was promoted out of. Listen 0.12.0 and later
    /// write it, and the meeting page's "Asked for" line opens it again.
    public var chat: String?
    public var recordings: [String]
    /// What this note is filed under, in the user's own words.
    ///
    /// One vocabulary with `Metadata.tags` on a recording, and carried
    /// explicitly: a note does not inherit a tag from a meeting it names.
    /// Listen 0.21.0 and later write it.
    ///
    /// `[String]` and not `[String]?`, which is the opposite of
    /// `Metadata.tags`. That Optional is load-bearing because `Metadata` uses
    /// the synthesized decoder, which throws `keyNotFound` on a missing key
    /// even where the property has a default. This type is read by a
    /// hand-rolled `parse` and a hand-written `init(from:)` with `try?` on
    /// every field, so there is no key here that can be missing.
    public var tags: [String]
    public var body: String

    /// Frontmatter this version has never heard of, kept exactly as it was
    /// read so that writing the note back does not delete it.
    ///
    /// The lesson is the same one `Metadata` learned and paid for twice: a
    /// device that re-serialises a document it did not author drops every field
    /// its own struct does not model, and nothing reports it. It happened here
    /// too, and it was live. Listen 0.12.0 added `prompt` and `chat`; this app
    /// modelled neither, so one note edit on the phone deleted both from a file
    /// the Mac had written, and **the sync could not notice**, because
    /// `version` is title, recordings and body, so the two sides agreed on a
    /// digest while holding different files.
    ///
    /// `prompt` and `chat` are modelled properly above, because the phone has
    /// reason to show them. This is for the next one.
    public var extra: [String: String]

    public var id: String { slug }

    /// The version token for compare-and-swap, and it is the **content**, not
    /// the clock.
    ///
    /// `updated` is a timestamp with one-second resolution, which is not a
    /// version: measured here, an edit on the Mac and an edit on the phone
    /// landed in the same second, produced identical `updated` values, and the
    /// sync concluded the two sides agreed while they held different text. One
    /// of them would have been lost the moment anything wrote again.
    ///
    /// A digest cannot do that. Same text is the same version however far apart
    /// the clocks are, and different text is a different version however close
    /// together the edits were. `updated` stays, because a human reading a note
    /// wants to know when it changed, but nothing decides anything with it.
    ///
    /// **`prompt`, `chat` and `extra` are deliberately not in here.** They are
    /// provenance rather than content: written once when the note is promoted
    /// out of a conversation and never edited afterwards, so a change to one is
    /// not an edit two people can race on. Leaving them out means a device that
    /// gains them does not have to re-sync every note to say so. It also means
    /// this digest cannot detect one being lost, which is exactly how they were
    /// being lost before `extra` existed, so preserving them is the safeguard
    /// and this is not.
    ///
    /// **`tags` is in here, and that is the one place this type's formula has
    /// ever moved.** They are not provenance: a tag is edited repeatedly, by
    /// hand and by an agent, so leaving it out is silent loss rather than
    /// saved traffic. A tag added on the Mac would produce no version change,
    /// never push, and then be overwritten the next time the phone edited the
    /// body, which is exactly the failure the paragraph above says this digest
    /// cannot detect.
    ///
    /// **Appended last, and only when there are tags**, which is the whole of
    /// what keeps the change affordable. Two devices computing this by
    /// different formulas push and pull the same note for ever: `pullNote`
    /// stamps the *sender's* digest into the base while push stamps its own,
    /// so neither side ever agrees. Every note written before this field
    /// existed produces the string it always produced, so nothing already on
    /// disk moves and the churn is bounded to notes that actually carry a tag,
    /// until the phone computes the same string. `CloudReport.pushedNotes` on
    /// a second consecutive pass is the number that says whether it has.
    ///
    /// Sorted and comma-joined the way `recordings` is, which is unambiguous
    /// only because `Tags.check` refuses a comma in a tag name.
    public var version: String {
        var canonical = title
        canonical += "\n" + recordings.sorted().joined(separator: ",")
        canonical += "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tags.isEmpty {
            canonical += "\n" + tags.sorted().joined(separator: ",")
        }
        return sha256Hex(Data(canonical.utf8))
    }

    public init(slug: String, title: String, created: String, updated: String,
                source: String, recordings: [String], body: String,
                prompt: String? = nil, chat: String? = nil,
                tags: [String] = [], extra: [String: String] = [:]) {
        self.slug = slug; self.title = title; self.created = created
        self.updated = updated; self.source = source
        self.prompt = prompt; self.chat = chat
        self.recordings = recordings; self.tags = tags
        self.body = body; self.extra = extra
    }

    /// Decoded leniently, so a note sent by a version that models more fields
    /// than this one arrives rather than failing. Same reasoning as `Metadata`:
    /// this type crosses between two apps that are updated separately.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = (try? c.decode(String.self, forKey: .title)) ?? slug
        created = (try? c.decode(String.self, forKey: .created)) ?? ""
        updated = (try? c.decode(String.self, forKey: .updated)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "you"
        prompt = try? c.decode(String.self, forKey: .prompt)
        chat = try? c.decode(String.self, forKey: .chat)
        recordings = (try? c.decode([String].self, forKey: .recordings)) ?? []
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        extra = (try? c.decode([String: String].self, forKey: .extra)) ?? [:]
    }

    /// Whether a slug is one this library will turn into a filename.
    ///
    /// The same hole as `Metadata.isValidID` and it was easy to miss, because a
    /// slug looks like a name rather than an address: `notes/<slug>.md` is
    /// built by `appendingPathComponent` exactly as a recording folder is, so
    /// `putNote` and `deleteNote` reach outside the library on a slug with
    /// `..` in it just as `get` does on an id.
    ///
    /// An allow-list rather than a list of forbidden characters, because the
    /// forbidden list is the one that is always missing an entry. This is a
    /// superset of what `Notes.slug(for:)` on the Mac produces (lowercase ASCII
    /// alphanumerics joined by hyphens, plus `-2` … `-99` for uniqueness) and
    /// it accepts the `<recording-id>-yours` slugs already on disk, whose hex
    /// is uppercase.
    public static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 96 else { return false }
        // A leading hyphen is not dangerous, but nothing generates one and it
        // reads as a flag to anything that later takes a slug on a command line.
        guard slug.first != "-" else { return false }
        return slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Parse the on-disk form. Hand-rolled rather than a YAML dependency
    /// because the frontmatter is a handful of scalar keys and one list, and a
    /// dependency here would have to build for iOS too.
    ///
    /// **A file with no frontmatter is still a note**, which is the whole point
    /// of keeping notes as markdown: `notes-tags-dictionary.md` requires that a
    /// note survive being written by hand, and somebody writing one by hand
    /// does not type a YAML block. Listen accepts such a file and takes its
    /// title from the first heading. This used to return nil for it, and
    /// because the server builds its manifest through this same function, a
    /// hand-written note was not merely hidden on the phone: it never entered
    /// the manifest, so it could not sync in either direction.
    ///
    /// `modified` stands in for `created` and `updated` when the file carries
    /// neither, because for a file somebody dropped in a folder the filesystem
    /// is the only thing that knows when it arrived.
    public static func parse(slug: String, _ text: String, modified: Date? = nil) -> Note? {
        let stamp = modified.map(Metadata.stamp) ?? ""
        guard text.hasPrefix("---\n"), let end = text.dropFirst(4).range(of: "\n---\n") else {
            return Note(slug: slug,
                        title: heading(in: text) ?? slug,
                        created: stamp, updated: stamp,
                        source: "you", recordings: [], body: text)
        }
        let rest = text.dropFirst(4)
        var fields: [String: String] = [:]
        // Kept with the quoting exactly as it was read, because writing it back
        // is the only thing this app does with it and re-quoting a value it
        // does not understand is how you corrupt one.
        var extra: [String: String] = [:]
        var sequences: [String: [String]] = [:]
        var openSequence: String?
        // `tags` is here rather than in `extra`, and modelling it fixed a hole
        // as well as adding a field. An unknown key with an **empty** value
        // takes both routes: `extra[key] = ""` from the scalar below, and its
        // `- ` lines into `sequences[key]`, which nothing reads. Serialising
        // then writes back a bare `tags:` and the list is gone. That is the
        // same failure the comment above records for `recordings`, and it is
        // still open for the next unknown key that arrives as a block
        // sequence. Modelling one is what closes it for that one.
        let known: Set<String> = ["title", "created", "updated", "source",
                                  "prompt", "chat", "recordings", "tags"]
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A YAML block sequence, which Listen accepts and never writes.
            // Skipping these lines produced an **empty** list rather than a
            // parse failure, and the empty list was then written back, so a
            // hand-edited note lost every meeting it was about on first touch.
            if let key = openSequence, trimmed.hasPrefix("- ") {
                sequences[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            openSequence = nil

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // An empty value is what a block sequence hangs from.
            if raw.isEmpty { openSequence = key }
            guard known.contains(key) else { extra[key] = raw; continue }
            fields[key] = unquote(raw)
        }
        // Block sequence first and the flow form second, for both of the list
        // fields. Listen writes the flow form and accepts either.
        func list(_ key: String) -> [String] {
            sequences[key] ?? (fields[key] ?? "[]")
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
        }
        return Note(slug: slug,
                    title: fields["title"] ?? heading(in: text) ?? slug,
                    created: fields["created"] ?? stamp,
                    updated: fields["updated"] ?? fields["created"] ?? stamp,
                    source: fields["source"] ?? "you",
                    recordings: list("recordings"),
                    body: String(rest[end.upperBound...]),
                    prompt: fields["prompt"],
                    chat: fields["chat"],
                    tags: list("tags"),
                    extra: extra)
    }

    /// A frontmatter scalar with its surrounding quotes taken off, if it had
    /// any. Listen quotes every string it writes; a human writing one by hand
    /// mostly does not.
    private static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.count > 1, v.hasPrefix("\""), v.hasSuffix("\"") else { return v }
        return String(v.dropFirst().dropLast())
    }

    /// The first markdown heading, which is what a hand-written note calls
    /// itself when it has no frontmatter to say so.
    private static func heading(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// The file as it goes to disk, in the same key order Listen writes, so a
    /// note that has been through this app is not diffable from one that has
    /// not. Unknown keys are written after the ones both apps know and before
    /// `recordings`, which is where Listen puts the two this version learned.
    ///
    /// `tags` sits in that same band, immediately before `extra`. A deployed
    /// client that does not model it holds it in `extra` and writes it out in
    /// the sorted loop, which lands in the same place, so the two produce
    /// byte-identical files and nothing churns.
    ///
    /// **`tags` is written even when it is empty, which is the opposite of
    /// what a recording does.** `Tags.write` stores an empty list as nil so
    /// that a recording with no tags is indistinguishable from one written
    /// before the field existed, and that is right there because only the
    /// authoring device ever serialises a recording's metadata. A note is the
    /// one sidecar both devices write, and `Library.writeNote` merges `extra`
    /// with "absent means unchanged". So if an empty list were spelled as an
    /// absent key, clearing a note's tags could never reach a peer that is
    /// still holding them in `extra`: the merge would put them straight back,
    /// and the two sides would agree on a digest while holding different
    /// files. Writing `tags: []` makes the clear an instruction that merge can
    /// see.
    public func serialised() -> String {
        let sources = recordings.map { "\"\($0)\"" }.joined(separator: ", ")
        let filed = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        var out = "---\n"
        out += "title: \"\(title)\"\n"
        out += "created: \(created)\n"
        out += "updated: \(updated)\n"
        out += "source: \(source)\n"
        if let prompt, !prompt.isEmpty { out += "prompt: \"\(prompt)\"\n" }
        if let chat, !chat.isEmpty { out += "chat: \"\(chat)\"\n" }
        out += "tags: [\(filed)]\n"
        for key in extra.keys.sorted() { out += "\(key): \(extra[key]!)\n" }
        out += "recordings: [\(sources)]\n"
        out += "---\n\n"
        return out + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Thrown when a note write loses the compare-and-swap. Carries the copy that
/// won, so the caller can show both rather than reporting a failure the user
/// cannot act on.
public struct NoteConflict: Error, Sendable {
    public let theirs: Note
    public init(theirs: Note) { self.theirs = theirs }
}
